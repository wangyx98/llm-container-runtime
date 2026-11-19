#!/bin/bash
# Postcondition oracle. Every check is dynamic: the images are removed from the node and pulled again through the CRI (what the kubelet calls): a pull without
# an account must be refused, a pull with the account given explicitly must work, and the registry's log tells whom containerd presented itself as.
set -e

CASE_ID="bench73910486"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
REG_DIR="$LIB_BASE/registry"
CTD_SOCK="$RUN_BASE/containerd.sock"
CTD_CONF="$LIB_BASE/etc/containerd.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
CRICTL() { sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" "$@"; }
# The last 500 characters of this output are all the report keeps: failures are one short line.
fail() { echo "FAIL: $*"; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true; }

ADDR=$(sj addr); PORT=$(sj port); USER=$(sj user); PASS=$(sj password); REPO=$(sj repo)
HOST="$ADDR:$PORT"
ACC='Accept: application/vnd.docker.distribution.manifest.v2+json'
newlog() { sudo tail -n +"$(( ${1} + 1 ))" "$REG_DIR/requests.log"; }

echo "[oracle] check 1: the lab is the one of setup: the registry is the recorded process, its files, account and content are unchanged and nothing was written to it,"
echo "[oracle] it still needs the account; containerd runs from its configuration file; no packet-forwarding rule exists..."
pid=$(sj daemons.registry | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])'); start=$(sj daemons.registry | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])')
[ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] || fail "the registry of setup is not running"
sudo python3 - "$STATE_DIR/state.json" "$REG_DIR/state.json" <<'PYEOF' || fail "a file of the lab was changed (see above)"
import hashlib, json, sys
d = json.load(open(sys.argv[1])); bad = []
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
for f, h in d["files"].items():
    try:
        if sha(f) != h: bad.append(f)
    except OSError: bad.append(f)
if sha(sys.argv[2]) != d["registry_state"]: bad.append("the registry's content")
if bad: print("changed: " + ", ".join(bad)); sys.exit(1)
PYEOF
if newlog "$(sj registry_lines)" | grep -qE '^(POST|PUT|PATCH|DELETE) '; then fail "something wrote to the registry"; fi
c=$(code "http://$HOST/v2/"); [ "$c" = "401" ] || fail "the registry answers /v2/ without an account with HTTP $c, not 401 (it must stay reachable and keep requiring the account)"
for tag in latest verify; do
    c=$(code -H "$ACC" "http://$HOST/v2/$REPO/manifests/$tag"); [ "$c" = "401" ] || fail "the registry answers $REPO:$tag without an account with HTTP $c, not 401"
    c=$(code -u "$USER:$PASS" -H "$ACC" "http://$HOST/v2/$REPO/manifests/$tag"); [ "$c" = "200" ] || fail "the registry answers $REPO:$tag to its account with HTTP $c, not 200"
done
if sudo iptables-save -t nat 2>/dev/null | grep -qE "$ADDR|dport $PORT"; then fail "a NAT rule redirects traffic of the registry's address or port"; fi
p=""; [ -s "$RUN_BASE/containerd.pid" ] && p=$(cat "$RUN_BASE/containerd.pid")
[ -n "$p" ] && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "containerd" ] && sudo tr '\0' ' ' < "/proc/$p/cmdline" | grep -qF -- "--config $CTD_CONF" || fail "the containerd that answers is not the one started from $CTD_CONF"
CRICTL version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
echo "  -> OK"

L1=$(sudo wc -l < "$REG_DIR/requests.log")
D="$STATE_DIR/oracle-$$"; sudo mkdir -p "$D/logs"
POD=""
cleanup_oracle() { [ -z "$POD" ] || { CRICTL stopp "$POD" >/dev/null 2>&1; CRICTL rmp -f "$POD" >/dev/null 2>&1; }; sudo rm -rf "$D"; }
trap cleanup_oracle EXIT

anon_check() {   # $1 = tag: the image is removed and pulled WITHOUT credentials: refused, and containerd presented no account of its own
    local tag="$1" ref="$HOST/$REPO:$1" out n0
    CRICTL rmi "$ref" >/dev/null 2>&1 || true
    n0=$(sudo wc -l < "$REG_DIR/requests.log")
    if out=$(CRICTL pull "$ref" 2>&1); then
        fail "$ref is pulled without any account: containerd still presents one of its own (the registry's log shows $(newlog "$n0" | grep -c 'auth=ok') authenticated requests)"
    fi
    if newlog "$n0" | grep -E 'ua=containerd/' | grep -qE 'auth=(ok|bad)'; then fail "the pull of $ref failed, but containerd sent an account of its own (the registry's log shows authenticated requests)"; fi
    newlog "$n0" | grep -E 'ua=containerd/' | grep -qE ' 401 ' || fail "the registry did not see containerd ask for $ref: the pull does not fail on the account"
    [ -z "$(CRICTL images -q 2>/dev/null | grep -F "$REPO:$tag" || true)" ] || fail "the node holds $ref after the refused pull"
}
creds_check() {  # $1 = tag: the same image pulled with the account given explicitly: the image of the registry, fetched by containerd with that account
    local tag="$1" ref="$HOST/$REPO:$1" man cfg out n0
    man=$(sj images.$tag.manifest); cfg=$(sj images.$tag.config)
    CRICTL rmi "$ref" >/dev/null 2>&1 || true
    n0=$(sudo wc -l < "$REG_DIR/requests.log")
    out=$(CRICTL pull --creds "$USER:$PASS" "$ref" 2>&1) || fail "the pull of $ref with the account fails: $(echo "$out" | tail -1 | grep -oE "(dial tcp|server gave|no such host|not found|denied|authorization failed|no basic auth)[^\"]{0,100}" | head -1)"
    CRICTL inspecti "$ref" 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin)["status"]; man, cfg = sys.argv[1:3]
assert s["id"] == cfg, "image id " + s["id"]
assert any(d.endswith("@" + man) for d in s.get("repoDigests", [])), "repoDigests " + str(s.get("repoDigests"))
' "$man" "$cfg" 2>&1 | tail -1 | grep . && fail "$ref was pulled with the account, but it is not the image of the registry (digest $man)"
    for want in "manifests/$man" "blobs/$cfg" "blobs/$(sj images.$tag.layer)"; do
        newlog "$n0" | grep -E "^(GET|HEAD) /v2/$REPO/$want(\?[^ ]*)? 200 ua=containerd/.*auth=ok" >/dev/null || fail "the registry did not see containerd fetch $REPO/$want with the account"
    done
}
run_check() {    # $1 = reference, $2 = token key
    local ref="$1" tok st cid
    tok=$(sj images.$2.token)
    sudo tee "$D/pod.json" >/dev/null <<JEOF
{"metadata":{"name":"oracle","namespace":"bench","uid":"u-oracle-$$-$2","attempt":1},"log_directory":"$D/logs","linux":{"security_context":{"namespace_options":{"network":2}}}}
JEOF
    sudo tee "$D/ctr.json" >/dev/null <<JEOF
{"metadata":{"name":"app"},"image":{"image":"$ref"},"log_path":"app-$2.log","linux":{}}
JEOF
    POD=$(CRICTL runp "$D/pod.json" 2>/dev/null | tail -1) || true
    [ -n "$POD" ] || fail "containerd cannot start a pod sandbox"
    cid=$(CRICTL create "$POD" "$D/ctr.json" "$D/pod.json" 2>&1 | tail -1) || true
    case "$cid" in [0-9a-f]???????????????*) ;; *) fail "no container can be created from $ref: $(echo "$cid" | cut -c1-200)" ;; esac
    CRICTL start "$cid" >/dev/null 2>&1 || fail "the container of $ref did not start"
    st=""
    for _ in $(seq 1 20); do
        st=$(CRICTL inspect "$cid" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["state"])' 2>/dev/null || true)
        [ "$st" = "CONTAINER_RUNNING" ] && break
        sleep 1
    done
    [ "$st" = "CONTAINER_RUNNING" ] || fail "the container of $ref is $st, not running"
    sleep 1
    CRICTL logs "$cid" 2>/dev/null | grep -q "token=$tok" || fail "the log of the container of $ref does not show the token of the image"
    CRICTL stopp "$POD" >/dev/null 2>&1; CRICTL rmp -f "$POD" >/dev/null 2>&1; POD=""
}

echo "[oracle] check 2: the images of the registry are removed from the node and pulled WITHOUT account or password (crictl pull, as the question does): both pulls must be"
echo "[oracle] refused, and containerd must not present an account of its own (the registry's log: only unauthenticated requests, answered 401)..."
anon_check latest
anon_check verify
echo "  -> OK"

echo "[oracle] check 3: the same pulls with the registry's account given explicitly (crictl pull --creds): the images of the registry, fetched by containerd with that"
echo "[oracle] account (manifest and both blobs in the registry's log); the container of the first one runs and prints the token of the image..."
creds_check latest
run_check "$HOST/$REPO:latest" latest
creds_check verify
run_check "$HOST/$REPO:verify" verify
echo "  -> OK"

echo "[oracle] check 4: the account given for those pulls was not kept: the images are removed again and an anonymous pull is still refused..."
anon_check latest
echo "  -> OK"
echo "[oracle] the registry is pulled from only with an account that the caller supplies; the node holds no account of its own."
