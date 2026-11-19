#!/bin/bash
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
daemon_ok() {   # $1 = crio|k3s|registry: the process of setup (pid + start time + program), not a zombie
    local pid start exe
    read -r pid start exe < <(sj "daemons.$1" | python3 -c 'import json,sys; print(*json.load(sys.stdin))')
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] \
        && [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "$exe" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }

echo "[precondition] checking the state setup recorded, and the three daemons (the registry, CRI-O, k3s)..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
for d in registry crio k3s; do daemon_ok "$d" || fail "the recorded $d is not running"; done
CRICTL version >/dev/null 2>&1 || fail "CRI-O does not answer on $CRIO_SOCK"
echo "  -> OK"

REPO=$(sj repo); TAG=$(sj tag); VTAG=$(sj vtag); REF=$(sj ref); USER=$(sj user); PASS=$(sj password); NODE=$(sj node)
MANIFEST=$(sj image.manifest)

echo "[precondition] checking the registry needs credentials: anonymous requests, and requests with a wrong password, are refused;"
echo "[precondition] the credentials of $WORK_DIR/registry.cred work; the repository of the sandbox image is anonymous..."
[ "$(code "http://$REG_HOST/v2/")" = "401" ] || fail "the registry answers an anonymous /v2/ with something else than 401"
[ "$(code "http://$REG_HOST/v2/$REPO/manifests/$TAG")" = "401" ] || fail "the private repository is open to anonymous requests"
[ "$(code -u "$USER:wrong-$PASS" "http://$REG_HOST/v2/$REPO/manifests/$TAG")" = "401" ] || fail "a wrong password is accepted"
[ "$(code -u "$USER:$PASS" "http://$REG_HOST/v2/$REPO/manifests/$TAG")" = "200" ] || fail "the credentials of setup do not work"
[ "$(code "http://$REG_HOST/v2/bench72183367/pause/manifests/1")" = "200" ] || fail "the sandbox image is not served anonymously"
grep -q "^username=$USER\$" "$WORK_DIR/registry.cred" && grep -q "^password=$PASS\$" "$WORK_DIR/registry.cred" || fail "registry.cred does not hold the registry's credentials"
D=$(curl -sI --max-time 5 -u "$USER:$PASS" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "http://$REG_HOST/v2/$REPO/manifests/$TAG" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')
[ "$D" = "$MANIFEST" ] || fail "the digest of $REPO:$TAG is not the recorded one"
echo "  -> OK ($D)"

echo "[precondition] checking Kubernetes (k3s) runs on CRI-O and the node is Ready..."
READY=$(K get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "$READY" = "True" ] || fail "the node $NODE is not Ready"
RT=$(K get node "$NODE" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
case "$RT" in cri-o://*) ;; *) fail "the node does not run on CRI-O ($RT)" ;; esac
echo "  -> OK ($RT)"

echo "[precondition] checking no credentials of the registry exist on the node (the places containers/image reads, CRI-O's"
echo "[precondition] configuration), and that CRI-O cannot pull the private image on its own..."
for f in /run/containers/0/auth.json /root/.config/containers/auth.json /root/.docker/config.json /etc/containers/auth.json /var/lib/kubelet/config.json; do
    ! sudo grep -qF "$REG_HOST" "$f" 2>/dev/null || fail "$f already holds credentials for $REG_HOST"
done
! sudo grep -q 'global_auth_file' "$LIB_BASE/crio/crio.conf" || fail "CRI-O's configuration names a global auth file"
OUT=$(CRICTL pull "$REG_HOST/$REPO:$VTAG" 2>&1) && fail "CRI-O pulled the private image without credentials"
echo "$OUT" | grep -qiE 'unauthorized|authentication required' || fail "the pull without credentials failed for another reason: '$(echo "$OUT" | tail -1 | cut -c1-200)'"
IMGS=$(CRICTL images -o json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(t for i in json.load(sys.stdin).get("images", []) for t in i.get("repoTags", []) + i.get("repoDigests", [])))')
case "$IMGS" in *"/$REPO"*) fail "an image of $REPO is already in the node's image store ($IMGS)" ;; esac
echo "  -> OK"

echo "[precondition] checking the pod app (namespace default) asks for $REF, has no imagePullSecrets, cannot start..."
J=$(K get pod app -o json 2>/dev/null) || fail "the pod app does not exist"
echo "$J" | python3 -c '
import json, sys
p = json.load(sys.stdin); ref = sys.argv[1]
assert p["spec"]["containers"][0]["image"] == ref, "image " + p["spec"]["containers"][0]["image"]
assert not p["spec"].get("imagePullSecrets"), "the pod has imagePullSecrets"
w = (p["status"]["containerStatuses"][0]["state"].get("waiting") or {})
assert w.get("reason") in ("ErrImagePull", "ImagePullBackOff"), "state %s" % p["status"]["containerStatuses"][0]["state"]
assert "unauthorized" in (w.get("message") or "") or w.get("reason") == "ImagePullBackOff", "message without unauthorized"
' "$REF" 2>&1 | head -3 | grep . && fail "the pod app is not as setup left it"
SA=$(K get serviceaccount default -o jsonpath='{.imagePullSecrets}' 2>/dev/null || true)
[ -z "$SA" ] || fail "the default ServiceAccount already has imagePullSecrets"
[ "$(K get secrets -A --no-headers --field-selector type=kubernetes.io/dockerconfigjson 2>/dev/null | wc -l)" = "0" ] || fail "a registry Secret already exists in the cluster"
[ "$(K get secrets -A --no-headers --field-selector type=kubernetes.io/dockercfg 2>/dev/null | wc -l)" = "0" ] || fail "a registry Secret already exists in the cluster"
echo "  -> OK"
echo "[precondition] the lab is as the task describes: the registry needs credentials, the pod app cannot pull its image."
