#!/bin/bash
# Postcondition oracle. Every check is dynamic: the images are removed from the node and pulled again through the CRI (what the kubelet calls) under the two
# names of the task, the containers made from them run and print their tokens, and the requests Nexus saw tell where each pull went.
set -e

CASE_ID="bench76379942"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
NEXUS_DIR="$LIB_BASE/nexus"
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
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }

ADDR=$(sj addr); PORT=$(sj port); ENG=$(sj eng_port)
WEB_REF="bench76379942/web:1.0"; API_REF="$ADDR:$ENG/bench76379942/api:1.0"
WEBV_REF="bench76379942/web:verify"; APIV_REF="$ADDR:$ENG/bench76379942/api:verify"
newlog() { sudo tail -n +"$(( ${1} + 1 ))" "$NEXUS_DIR/requests.log"; }

echo "[oracle] check 1: the lab is the one of setup: the Nexus stand-in is the recorded process, its files and content are unchanged and nothing was written to it;"
echo "[oracle] containerd runs from its configuration file; Nexus' connector is where it was, port $ENG has no listener and no forwarding rule exists..."
pid=$(sj daemons.nexus | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])'); start=$(sj daemons.nexus | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])')
[ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null | tr -d ')')" = "$start" ] || fail "the Nexus stand-in of setup is not running"
sudo python3 - "$STATE_DIR/state.json" "$NEXUS_DIR/state.json" <<'PYEOF' || fail "a file of the lab was changed (see above)"
import hashlib, json, sys
d = json.load(open(sys.argv[1])); bad = []
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
for f, h in d["files"].items():
    try:
        if sha(f) != h: bad.append(f)
    except OSError: bad.append(f)
if sha(sys.argv[2]) != d["nexus_state"]: bad.append("Nexus' content")
if bad: print("changed: " + ", ".join(bad)); sys.exit(1)
PYEOF
if newlog "$(sj nexus_lines)" | grep -qE '^(POST|PUT|PATCH|DELETE) '; then fail "something wrote to Nexus"; fi
[ "$(code "http://$ADDR:$PORT/v2/")" = "200" ] || fail "Nexus' connector does not answer on $ADDR:$PORT"
! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$ENG\$" || fail "something listens on port $ENG: the names must reach Nexus' connector through containerd's configuration"
if sudo iptables-save -t nat 2>/dev/null | grep -qE "$ADDR|:$ENG|:$PORT|dport $ENG|dport $PORT"; then fail "a NAT rule redirects traffic of Nexus' addresses or ports"; fi
p=""; [ -s "$RUN_BASE/containerd.pid" ] && p=$(cat "$RUN_BASE/containerd.pid")
[ -n "$p" ] && [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "containerd" ] && sudo tr '\0' ' ' < "/proc/$p/cmdline" | grep -qF -- "--config $CTD_CONF" || fail "the containerd that answers is not the one started from $CTD_CONF"
CRICTL version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
echo "  -> OK"

L1=$(sudo wc -l < "$NEXUS_DIR/requests.log")
D="$STATE_DIR/oracle-$$"; sudo mkdir -p "$D/logs"
POD=""
cleanup_oracle() { [ -z "$POD" ] || { CRICTL stopp "$POD" >/dev/null 2>&1; CRICTL rmp -f "$POD" >/dev/null 2>&1; }; sudo rm -rf "$D"; }
trap cleanup_oracle EXIT

pull_check() {   # $1 = key of the image in the state, $2 = the reference the task names
    local k="$1" ref="$2" man cfg
    man=$(sj images.$k.manifest); cfg=$(sj images.$k.config)
    CRICTL rmi "$ref" >/dev/null 2>&1 || true
    local out; out=$(CRICTL pull "$ref" 2>&1) || fail "the pull of $ref fails: $(echo "$out" | tail -1 | grep -oE "(dial tcp|server gave|no such host|not found|denied)[^\"]{0,100}" | head -1)"
    CRICTL inspecti "$ref" 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin)["status"]; man, cfg = sys.argv[1:3]
assert s["id"] == cfg, "image id " + s["id"]
assert any(d.endswith("@" + man) for d in s.get("repoDigests", [])), "repoDigests " + str(s.get("repoDigests"))
' "$man" "$cfg" 2>&1 | tail -1 | grep . && fail "$ref was pulled, but it is not the image Nexus holds (digest $man)"
    return 0
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
saw() {          # $1 = repo, $2 = what follows /v2/<repo>/ : the requests of containerd after the start of the pulls, answered 200
    newlog "$L1" | grep -E "^(GET|HEAD) /v2/$1/$2[ ?].* 200 ua=containerd/" >/dev/null
}

echo "[oracle] check 2: the default name $WEB_REF (docker.io/...) is removed from the node and pulled: it is the image of Nexus (digest and image id),"
echo "[oracle] its container runs and prints the token, and Nexus saw containerd fetch its manifest..."
pull_check web "$WEB_REF"
saw bench76379942/web "manifests/$(sj images.web.manifest)" || fail "Nexus did not see containerd fetch the manifest of $WEB_REF: the pull was not served by Nexus"
run_check "$WEB_REF" web
echo "  -> OK"

echo "[oracle] check 3: the explicit name $API_REF: the same..."
pull_check api "$API_REF"
saw bench76379942/api "manifests/$(sj images.api.manifest)" || fail "Nexus did not see containerd fetch the manifest of $API_REF"
run_check "$API_REF" api
echo "  -> OK"

echo "[oracle] check 4: a second image of each repository, never on the node before, is pulled under the same names: Nexus must see containerd fetch its"
echo "[oracle] manifest and both blobs (the configuration does not depend on what is cached)..."
L1=$(sudo wc -l < "$NEXUS_DIR/requests.log")
pull_check webv "$WEBV_REF"
pull_check apiv "$APIV_REF"
for k in webv apiv; do
    repo=$(sj images.$k.repo)
    for want in "manifests/$(sj images.$k.manifest)" "blobs/$(sj images.$k.config)" "blobs/$(sj images.$k.layer)"; do
        saw "$repo" "$want" || fail "Nexus did not see containerd fetch $repo/$want"
    done
done
echo "  -> OK"
echo "[oracle] both names reach Nexus through containerd's configuration, on the connector's real port; nothing else was changed."
