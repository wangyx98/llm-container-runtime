#!/bin/bash
set -e

CASE_ID="bench67635227"
LIB="/var/lib/$CASE_ID"
SNAP_DATA="$LIB/current"
ARGS="$SNAP_DATA/args"
SOCK="$LIB/common/run/containerd.sock"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTL="$STATE_DIR/ctl"
ADDR="127.67.63.52"
REG_PORT=5000
REPO="benchlab67635/app"
REF="docker.io/$REPO:v1"

fail() { echo "  -> FAIL: $*"; exit 1; }
node_crictl() { sudo crictl -r "unix://$SOCK" -i "unix://$SOCK" --timeout 60s "$@"; }
ctl_crictl() { sudo crictl -r "unix://$CTL/common/run/containerd.sock" -i "unix://$CTL/common/run/containerd.sock" --timeout 60s "$@"; }
hub_lines() { sudo wc -l < "$RUN/hub.log"; }
# what the hub logged since line $1, one word per request: kind(token|registry) method status who
hub_since() { sudo tail -n +"$(($1 + 1))" "$RUN/hub.log" | python3 -c '
import json
import sys

for ln in sys.stdin:
    r = json.loads(ln)
    print(r["srv"], r["method"], r["status"], r["who"], r["auth"], r["path"])'; }

echo "[precondition] the lab is as its record says: programs and account unchanged, the hub process the one setup started, the node running with the sandbox image..."
sudo sh -c 'cd / && sha256sum -c --quiet "$1/lab.sha"' _ "$STATE_DIR" >/dev/null 2>&1 || fail "a program of the lab or the account was changed"
HUB_PID=$(sudo cat "$STATE_DIR/hub.pid")
[ "$(sudo awk '{print $22}' "/proc/$HUB_PID/stat" 2>/dev/null)" = "$(sudo cat "$STATE_DIR/hub.start")" ] || fail "the hub is not the process setup started"
sudo "$LIB/bin/mk8sctl" status >/dev/null || fail "the node is not running"
node_crictl inspecti -o json "$CASE_ID.local/pause:1" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])' | cmp -s - <(sudo cat "$STATE_DIR/pause.id") || fail "the sandbox image of the node is not the imported one"
echo "  -> OK"

echo "[precondition] the engineer's registry settings: docker.io is mirrored to the hub and the authentication block is empty, in the template and in the generated file..."
for f in containerd-template.toml containerd.toml; do
    sudo grep -qF "endpoint = ['http://$ADDR:$REG_PORT']" "$ARGS/$f" || fail "$f does not send docker.io to the hub"
    sudo grep -qE "registry\.configs\.'docker\.io'\.auth" "$ARGS/$f" || fail "$f has no auth block for docker.io"
    ! sudo grep -qE "^[[:space:]]*(username|password|auth|identitytoken)[[:space:]]*=[[:space:]]*'[^']" "$ARGS/$f" || fail "$f already holds credentials"
    ! sudo grep -qE "^[[:space:]]*config_path[[:space:]]*=[[:space:]]*'[^']" "$ARGS/$f" || fail "$f has a config_path already"
done
echo "  -> OK"

echo "[precondition] the problem: a new pull of docker.io/$REPO by the node is refused with the rate-limit error, as an anonymous request..."
N0=$(hub_lines)
OUT=$(node_crictl pull "$REF" 2>&1) && fail "the pull worked: $OUT"
echo "$OUT" | grep -qi "toomanyrequests" || fail "the pull failed with another error: $(echo "$OUT" | tail -1 | cut -c1-200)"
hub_since "$N0" | grep -q "^registry GET 429 anonymous " || fail "the hub did not answer 429 to an anonymous GET"
! hub_since "$N0" | grep -q " basic " || fail "the node used credentials"
echo "  -> OK: $(echo "$OUT" | grep -io 'toomanyrequests: [^"]*' | head -1 | cut -c1-120)"

PW=$(sudo python3 -c 'import json; print(json.load(open("'"$LIB"'/account.json"))["password"])')
start_ctl() {   # a throw-away containerd (own root, state and socket) with the node's template, $1 = text appended to it, $2 = a sed script applied to it
    sudo rm -rf "$CTL"
    sudo install -d -m 700 "$CTL" "$CTL/common/run" "$CTL/common/var/lib/containerd"
    { sudo cat "$ARGS/containerd-template.toml" | sed -e "${2:-}"; echo "$1"; } | sed -e "s@\${SNAP_DATA}@$SNAP_DATA@g" -e "s@\${SNAP_COMMON}@$CTL/common@g" | sudo tee "$CTL/containerd.toml" >/dev/null
    sudo sh -c "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin setsid nohup containerd --config '$CTL/containerd.toml' >'$CTL/containerd.log' 2>&1 </dev/null &"
    for _ in $(seq 60); do sudo test -S "$CTL/common/run/containerd.sock" && ctl_crictl version >/dev/null 2>&1 && return 0; sleep 0.5; done
    fail "the control containerd did not start: $(sudo tail -3 "$CTL/containerd.log")"
}
stop_ctl() {
    sudo pkill -TERM -f -- "--config $CTL/[c]ontainerd.toml" 2>/dev/null || true
    for _ in $(seq 20); do sudo pgrep -f -- "--config $CTL/[c]ontainerd.toml" >/dev/null || break; sleep 0.5; done
    sudo pkill -KILL -f -- "--config $CTL/[c]ontainerd.toml" 2>/dev/null || true
    sudo rm -rf "$CTL"
}

echo "[precondition] control 1: the same template with the account filled in under the key 'docker.io' is still refused, the requests are anonymous..."
start_ctl "" "s/^  username = ''/  username = 'hubuser'/;s/^  password = ''/  password = '$PW'/"
N0=$(hub_lines)
OUT=$(ctl_crictl pull "$REF" 2>&1) && { stop_ctl; fail "the pull worked with the account under the key docker.io"; }
echo "$OUT" | grep -qi "toomanyrequests" || { stop_ctl; fail "the pull failed with another error: $(echo "$OUT" | tail -1 | cut -c1-200)"; }
! hub_since "$N0" | grep -q " basic " || { stop_ctl; fail "the account was sent although the key is docker.io"; }
stop_ctl
echo "  -> OK"

echo "[precondition] control 2: the same template with the account under the key of the endpoint ($ADDR:$REG_PORT) pulls the image, as the account (the lab can be solved)..."
start_ctl "
[plugins.'io.containerd.cri.v1.images'.registry.configs.'$ADDR:$REG_PORT'.auth]
  username = 'hubuser'
  password = '$PW'"
N0=$(hub_lines)
OUT=$(ctl_crictl pull "$REF" 2>&1) || { stop_ctl; fail "the pull with the account under the endpoint's key failed: $(echo "$OUT" | tail -1 | cut -c1-200)"; }
hub_since "$N0" | grep -q "^token GET 200 hubuser basic " || { stop_ctl; fail "the token service did not see the account"; }
hub_since "$N0" | grep -q "^registry GET 200 hubuser bearer .*blobs" || { stop_ctl; fail "the hub did not serve the blobs to the account"; }
stop_ctl
echo "  -> OK"

echo "[precondition] PASS - the node is refused with the rate-limit error; the account under the key 'docker.io' does not help, the same under the endpoint's key does."
