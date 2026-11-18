#!/bin/bash
set -e

CASE_ID="bench59759658"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN_BASE/containerd.sock"
CTR="sudo ctr -a $SOCK"

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }

echo "[precondition] checking the node's containerd is the recorded process and answers..."
PID=$(st "d['pid']")
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat" 2>/dev/null)" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded containerd"
$CTR version >/dev/null 2>&1 || fail "the node's containerd does not answer"
echo "  -> OK (pid $PID)"

echo "[precondition] checking the project, the wrappers and the tools are there..."
for f in "$WORK_DIR/app/compose.yaml" "$WORK_DIR/app/Dockerfile" "$WORK_DIR/app/app" "$WORK_DIR/app/nonce.txt" "$WORK_DIR/bin/nerdctl" "$WORK_DIR/bin/docker-compose" \
         "$LIB_BASE/bin/nerdctl" "$LIB_BASE/bin/buildkitd" "$LIB_BASE/bin/buildctl" "$LIB_BASE/bin/docker-compose" "$LIB_BASE/cni/bridge" "$LIB_BASE/cni/portmap"; do
    [ -s "$f" ] || fail "$f is missing"
done
grep -q '^ *build:' "$WORK_DIR/app/compose.yaml" || fail "the compose file has no build: section"
echo "  -> OK"

echo "[precondition] nothing is built or running yet: no BuildKit process, no image and no container in the node, no BuildKit data in the node's 'buildkit' namespace..."
! pgrep -a buildkitd | grep -q "$CASE_ID" || fail "a BuildKit for this case is already running"
[ ! -S "$RUN_BASE/buildkitd.sock" ] || fail "$RUN_BASE/buildkitd.sock already exists"
[ -z "$($CTR -n default images ls -q 2>/dev/null)" ] || fail "the node already has an image in its default namespace"
[ -z "$($CTR -n default containers ls -q 2>/dev/null)" ] || fail "the node already has a container"
[ "$($CTR -n buildkit snapshots ls 2>/dev/null | awk '$3 == "Committed"' | wc -l)" = "0" ] || fail "the node already has a BuildKit build"
echo "  -> OK"

echo "[precondition] symptom 1: the compose command of the thread (docker-compose build) wants a Docker API, which this node does not have..."
OUT=$(cd "$WORK_DIR/app" && "$WORK_DIR/bin/docker-compose" build 2>&1) && fail "docker-compose build worked without a Docker API"
echo "$OUT" | grep -q "Cannot connect to the Docker daemon" || fail "docker-compose build failed, but not with 'Cannot connect to the Docker daemon': $(echo "$OUT" | tail -2)"
echo "  -> OK ($(echo "$OUT" | grep 'Cannot connect' | head -1 | cut -c1-120))"

echo "[precondition] symptom 2: the containerd-native front end, 'nerdctl compose up -d --build', does not work as it is either: it needs the CNI plugins and a BuildKit..."
OUT=$("$WORK_DIR/bin/nerdctl" compose -f "$WORK_DIR/app/compose.yaml" up -d --build 2>&1) && fail "nerdctl compose up worked with nothing prepared"
echo "$OUT" | grep -q 'needs CNI plugin' || fail "nerdctl compose failed, but not on the CNI plugins: $(echo "$OUT" | tail -2)"
echo "  -> OK ($(echo "$OUT" | grep 'needs CNI' | head -1 | cut -c1-110))"

echo "[precondition] the failed attempts left nothing behind: still no image, no container, no BuildKit..."
[ -z "$($CTR -n default images ls -q 2>/dev/null)" ] || fail "an image appeared"
[ -z "$($CTR -n default containers ls -q 2>/dev/null)" ] || fail "a container appeared"
! pgrep -a buildkitd | grep -q "$CASE_ID" || fail "a BuildKit appeared"
echo "  -> OK"

echo "[precondition] ALL CHECKS PASSED"
