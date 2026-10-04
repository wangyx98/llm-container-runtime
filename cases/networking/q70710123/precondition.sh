#!/bin/bash
set -e

CASE_ID="bench70710123"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
IMAGE_REF="docker.io/library/$CASE_ID:latest"
PORT=7070
URL="http://host.docker.internal:$PORT/"

echo "[precondition] checking containerd answers and the image $IMAGE_REF is imported..."
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
if ! sudo ctr images ls -q 2>/dev/null | grep -qFx "$IMAGE_REF"; then
    echo "  -> FAIL: containerd does not list the image $IMAGE_REF"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking no container of this case exists yet (none named after it, none"
echo "[precondition] made from the image)..."
for c in $(sudo ctr containers ls -q 2>/dev/null); do
    FOUND=$(sudo ctr containers info "$c" 2>/dev/null | python3 -c '
import json, sys
ref, cid, case = sys.argv[1:4]
info = json.load(sys.stdin)
name = (info.get("Labels") or {}).get("nerdctl/name", "")
if info.get("Image") == ref or case in cid or case in name:
    print("yes")' "$IMAGE_REF" "$c" "$CASE_ID" 2>/dev/null || true)
    if [ -n "$FOUND" ]; then
        echo "  -> FAIL: container '$c' of this case already exists"
        exit 1
    fi
done
echo "  -> OK"

echo "[precondition] checking the host's test service answers on 127.0.0.1:$PORT with the run's token,"
echo "[precondition] and also on the host's own address (it listens on all interfaces)..."
TOKEN=$(cat "$STATE_DIR/token")
if ! curl -fsS --noproxy '*' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null | grep -qFx "token=$TOKEN"; then
    echo "  -> FAIL: the host test service does not answer on 127.0.0.1:$PORT"
    exit 1
fi
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
[ -n "$HOST_IP" ] || HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$HOST_IP" ]; then
    if ! curl -fsS --noproxy '*' --max-time 3 "http://$HOST_IP:$PORT/" 2>/dev/null | grep -qFx "token=$TOKEN"; then
        echo "  -> FAIL: the host test service does not answer on the host's address $HOST_IP:$PORT"
        exit 1
    fi
    echo "  -> OK (also on $HOST_IP)"
else
    echo "  -> OK (no non-loopback address found to try)"
fi

echo "[precondition] checking the name host.docker.internal is not defined on this machine..."
if getent hosts host.docker.internal >/dev/null 2>&1; then
    echo "  -> FAIL: host.docker.internal already resolves on this machine ($(getent hosts host.docker.internal))"
    exit 1
fi
echo "  -> OK"

# the symptom of the task, with the tool the task is about: a container started the usual way
# cannot resolve the name. (Skipped only on a test machine without nerdctl, see setup.sh.)
if command -v nerdctl >/dev/null 2>&1; then
    echo "[precondition] checking the symptom: a throw-away container started with a plain nerdctl run"
    echo "[precondition] cannot resolve host.docker.internal..."
    RC=0
    OUT=$(timeout -k 5 90 sudo nerdctl run --rm --name "$CASE_ID-precheck" "$IMAGE_REF" /usr/bin/probe fetch "$URL" </dev/null 2>&1) || RC=$?
    if [ "$RC" = "0" ]; then
        echo "  -> FAIL: a plain nerdctl run container already reaches the host service: $OUT"
        exit 1
    fi
    if ! printf '%s' "$OUT" | grep -q "cannot resolve"; then
        echo "  -> FAIL: the throw-away container did not fail the expected way (exit $RC): $(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-300)"
        exit 1
    fi
    echo "  -> OK ($(printf '%s' "$OUT" | grep "cannot resolve" | head -1))"
else
    echo "[precondition] nerdctl is not installed on this test machine: skipping the throw-away container check"
fi

echo "[precondition] PASS - the image is imported, no container exists, the host service answers"
echo "[precondition]        and the name host.docker.internal is not defined."
