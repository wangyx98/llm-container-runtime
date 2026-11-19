#!/bin/bash
# Postcondition oracle. Every check is dynamic: the pod that runs, the image id it reports, its log, the Secret it
# references, the requests the registry saw, and a pull of a second image made by a new pod that uses the same
# Secrets (so the pulling is done by the kubelet and CRI-O, on a node that has never held that image).
set -e

CASE_ID="bench72183367"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
REG_DIR="$LIB_BASE/registry"
REG_PORT=15183
REG_HOST="127.0.0.1:$REG_PORT"
CRIO_SOCK="$RUN_BASE/crio.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
K3S_BIN=$(sj k3s_bin 2>/dev/null || true)
K() { sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml K3S_DATA_DIR="$LIB_BASE/k3s" "$K3S_BIN" kubectl "$@"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CRIO_SOCK" --image-endpoint "unix://$CRIO_SOCK" "$@"; }
daemon_ok() {
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
# The last 500 characters of this output are all the report keeps: failures are one short line.
fail() { echo "FAIL: $*"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }

REPO=$(sj repo); VTAG=$(sj vtag); REF=$(sj ref); USER=$(sj user); PASS=$(sj password); NODE=$(sj node)
TOKEN=$(sj token); VTOKEN=$(sj vtoken); MANIFEST=$(sj image.manifest); CONFIGD=$(sj image.config)
VMANIFEST=$(sj vimage.manifest); VCONFIGD=$(sj vimage.config); VLAYERD=$(sj vimage.layer); LAYERD=$(sj image.layer)
L0=$(sj registry_lines)
newlog() { sudo tail -n +"$(( ${1:-$L0} + 1 ))" "$REG_DIR/requests.log"; }

echo "[oracle] check 1: the lab is the one of setup (registry, CRI-O and k3s are the recorded processes; their programs,"
echo "[oracle] configuration and the registry's content are unchanged) and the registry still requires credentials..."
for d in registry crio k3s; do daemon_ok "$d" || fail "the $d of setup is not running (or was replaced)"; done
sudo python3 - "$STATE_DIR/state.json" "$REG_DIR/state.json" <<'PYEOF' || fail "a file of the lab was changed (see above)"
import hashlib, json, sys
d = json.load(open(sys.argv[1])); bad = []
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
for f, h in d["files"].items():
    try:
        if sha(f) != h: bad.append(f)
    except OSError: bad.append(f)
if sha(sys.argv[2]) != d["registry_state"]:
    bad.append("registry content")
if bad: print("changed: " + ", ".join(bad)); sys.exit(1)
PYEOF
if newlog | grep -qE '^(POST|PUT|PATCH|DELETE) '; then fail "something wrote to the registry"; fi
[ "$(code "http://$REG_HOST/v2/")" = "401" ] || fail "the registry no longer refuses anonymous requests"
[ "$(code "http://$REG_HOST/v2/$REPO/manifests/$VTAG")" = "401" ] || fail "the private repository is open to anonymous requests"
[ "$(code -u "$USER:wrong-$PASS" "http://$REG_HOST/v2/$REPO/manifests/$VTAG")" = "401" ] || fail "the registry accepts a wrong password"
[ "$(code -u "$USER:$PASS" "http://$REG_HOST/v2/$REPO/manifests/$VTAG")" = "200" ] || fail "the registry does not accept the credentials of setup"
READY=""
for _ in $(seq 1 30); do
    READY=$(K get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [ "$READY" = "True" ] && break
    sleep 2
done
[ "$READY" = "True" ] || fail "the node $NODE is not Ready"
echo "  -> OK"

echo "[oracle] check 2: the node holds no credentials of its own for the registry (no auth file where containers/image looks,"
echo "[oracle] none in the kubelet's directory), and CRI-O cannot pull the private image without credentials..."
for f in /run/containers/0/auth.json /root/.config/containers/auth.json /root/.docker/config.json /etc/containers/auth.json /var/lib/kubelet/config.json; do
    ! sudo grep -qF "$REG_HOST" "$f" 2>/dev/null || fail "$f holds credentials for $REG_HOST: they must come from the pod's imagePullSecrets"
done
OUT=$(CRICTL pull "$REG_HOST/$REPO:$VTAG" 2>&1) && fail "CRI-O pulls from the private repository without credentials: the node has credentials of its own"
echo "$OUT" | grep -qiE 'unauthorized|authentication required' || fail "the pull without credentials failed for another reason: $(echo "$OUT" | tail -1 | cut -c1-120)"
echo "  -> OK"

echo "[oracle] check 3: a pod that asks for $REF RUNS, its pod spec names imagePullSecrets, one of them is a registry Secret"
echo "[oracle] with the right credentials for $REG_HOST, its image id is the registry's image, and its log shows the image's token..."
PODS=$(K get pods -A -o json 2>/dev/null) || fail "cannot list the pods"
SEL=$(echo "$PODS" | python3 -c '
import json, sys
ref, manifest, config, host, repo = sys.argv[1:6]
want = (ref, "%s/%s@%s" % (host, repo, manifest))
for p in json.load(sys.stdin)["items"]:
    if p["metadata"]["name"] == "bench-verify": continue
    st = p.get("status", {}); cs = st.get("containerStatuses") or []
    for c in p["spec"]["containers"]:
        if c["image"] not in want: continue
        s = [x for x in cs if x["name"] == c["name"]]
        if not s or not s[0].get("ready") or "running" not in s[0].get("state", {}) or s[0].get("restartCount", 1) != 0: continue
        iid = s[0].get("imageID", "")
        if manifest not in iid and config not in iid: continue
        print(p["metadata"]["namespace"], p["metadata"]["name"], s[0]["containerID"].split("://")[-1],
              ",".join(x["name"] for x in p["spec"].get("imagePullSecrets") or []))
        sys.exit(0)
' "$REF" "$MANIFEST" "$CONFIGD" "$REG_HOST" "$REPO") || true
[ -n "$SEL" ] || fail "no pod that asks for $REF is Running and Ready with the registry's image id (and no restarts)"
read -r NS PNAME CID SECRETS <<<"$SEL"
[ -n "$SECRETS" ] || fail "the pod $NS/$PNAME runs without imagePullSecrets in its spec"
GOOD=""
for s in ${SECRETS//,/ }; do
    ok=$(K -n "$NS" get secret "$s" -o json 2>/dev/null | python3 -c '
import base64, json, sys
host, user, pw = sys.argv[1:4]
s = json.load(sys.stdin)
if s.get("type") not in ("kubernetes.io/dockerconfigjson", "kubernetes.io/dockercfg"): sys.exit(1)
raw = s["data"].get(".dockerconfigjson") or s["data"].get(".dockercfg")
d = json.loads(base64.b64decode(raw)); d = d.get("auths", d)
e = d.get(host)
if not e: sys.exit(1)
u, p = e.get("username"), e.get("password")
if not u and e.get("auth"): u, _, p = base64.b64decode(e["auth"]).decode().partition(":")
sys.exit(0 if (u, p) == (user, pw) else 1)' "$REG_HOST" "$USER" "$PASS" && echo yes || true)
    [ "$ok" = "yes" ] && GOOD="$s" && break
done
[ -n "$GOOD" ] || fail "none of the imagePullSecrets of $NS/$PNAME ($SECRETS) is a registry Secret with the right server $REG_HOST, username and password"
CRICTL logs "$CID" 2>/dev/null | grep -q "token=$TOKEN" || fail "the log of the container of $NS/$PNAME does not show the token of the image"
echo "  -> OK (pod $NS/$PNAME, Secret $GOOD)"

echo "[oracle] check 4: the node has never held the second image of the repository, and a new pod with the same imagePullSecrets"
echo "[oracle] pulls it: it must run, and the registry must see CRI-O fetch the manifest and both blobs WITH the credentials..."
L1=$(sudo wc -l < "$REG_DIR/requests.log")
python3 - "$NS" "$REG_HOST/$REPO:$VTAG" "$SECRETS" <<'PYEOF' | K apply -f - >/dev/null || fail "could not create the verification pod"
import json, sys
ns, image, secrets = sys.argv[1:4]
print(json.dumps({"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "bench-verify", "namespace": ns},
    "spec": {"terminationGracePeriodSeconds": 1, "containers": [{"name": "v", "image": image}],
             "imagePullSecrets": [{"name": s} for s in secrets.split(",")]}}))
PYEOF
VST=""
for _ in $(seq 1 50); do
    VST=$(K -n "$NS" get pod bench-verify -o jsonpath='{.status.phase}/{.status.containerStatuses[0].ready}' 2>/dev/null || true)
    [ "$VST" = "Running/true" ] && break
    sleep 2
done
VCID=$(K -n "$NS" get pod bench-verify -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's#.*://##')
VMSG=$(K -n "$NS" get pod bench-verify -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null | cut -c1-150)
VOK=""
[ "$VST" = "Running/true" ] && [ -n "$VCID" ] && CRICTL logs "$VCID" 2>/dev/null | grep -q "token=$VTOKEN" && VOK=yes
NEW=$(newlog "$L1")
K -n "$NS" delete pod bench-verify --wait=false >/dev/null 2>&1 || true
[ "$VOK" = "yes" ] || fail "the verification pod did not run the second image ($VST $VMSG): the Secrets do not let the kubelet pull"
for want in "manifests/$VTAG" "blobs/$VCONFIGD" "blobs/$VLAYERD"; do
    echo "$NEW" | grep -E "^GET /v2/$REPO/$want 200 ua=cri-o.* auth=ok" >/dev/null || fail "the registry did not see CRI-O fetch $want with the credentials"
done
echo "  -> OK"
echo "[oracle] the pod $NS/$PNAME runs the private image, pulled with the credentials of the Secret $GOOD; the node has no credentials of its own."
