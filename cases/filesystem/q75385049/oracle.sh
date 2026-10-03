#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75385049"
NS="$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/bench75385049-hello:latest"
CHECK_ID="bench75385049-check"

echo "[oracle] check 0: containerd must be up and ctr must be able to talk to it..."
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: ctr cannot talk to containerd"; exit 1; }
TOKEN=$(cat "$STATE_DIR/token" 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
    echo "  -> FAIL: setup's recorded token is missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 1: 'ctr -n $NS images ls' must list $IMAGE_REF..."
LISTED=$(sudo ctr -n "$NS" images ls -q 2>/dev/null | grep -v '^$' || true)
if ! echo "$LISTED" | grep -qxF "$IMAGE_REF"; then
    echo "  -> FAIL: '$IMAGE_REF' is not listed in namespace $NS (listed there: ${LISTED:-nothing})"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: a container run from that image must work and print the line"
echo "[oracle]          that only the archive's program prints (its random token)..."
sudo ctr -n "$NS" tasks rm -f "$CHECK_ID" >/dev/null 2>&1 || true
sudo ctr -n "$NS" containers rm "$CHECK_ID" >/dev/null 2>&1 || true
# stdin comes from /dev/null on purpose: 'ctr run' copies its stdin into the
# container, and 'timeout' runs it in a background process group, where a read
# from a terminal stops the process (SIGTTIN). Run from a user's terminal that
# made every run hang until the 30 s limit, although the container itself had
# long finished.
OUT=$(sudo timeout -k 5 30 ctr -n "$NS" run --rm "$IMAGE_REF" "$CHECK_ID" </dev/null 2>&1) && RC=0 || RC=$?
# a wrong image that never exits would leave its container behind
sudo ctr -n "$NS" tasks kill -s SIGKILL "$CHECK_ID" >/dev/null 2>&1 || true
sudo ctr -n "$NS" tasks rm -f "$CHECK_ID" >/dev/null 2>&1 || true
sudo ctr -n "$NS" containers rm "$CHECK_ID" >/dev/null 2>&1 || true
if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then
    echo "  -> FAIL: the container run from $IMAGE_REF did not exit within 30 s (the archive's program prints one line and exits)"
    exit 1
fi
if [ "$RC" -ne 0 ]; then
    echo "  -> FAIL: 'ctr run' of $IMAGE_REF failed (exit $RC): $(echo "$OUT" | tail -3)"
    exit 1
fi
if ! echo "$OUT" | grep -qxF "bench75385049-hello token=$TOKEN"; then
    echo "  -> FAIL: the container did not print the archive's line (got: $(echo "$OUT" | tail -3))"
    exit 1
fi
echo "  -> OK"

echo "[oracle] all checks passed."
