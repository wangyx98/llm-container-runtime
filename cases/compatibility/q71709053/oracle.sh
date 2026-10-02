#!/bin/bash
set -e

CTD_SOCK="/run/containerd/containerd.sock"
CASE_ID="bench71709053"
RUN_DIR="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BASE_TAG="$CASE_ID-base:local"
CHILD_TAG="$CASE_ID-child:local"

NERDCTL="sudo nerdctl --address unix://$CTD_SOCK --namespace default"

echo "[oracle] check 0: containerd must be up, and BuildKit must still be the very"
echo "[oracle]          daemon setup started (it is shared; not to be restarted or"
echo "[oracle]          reconfigured)..."
sudo systemctl is-active --quiet containerd || { echo "  -> FAIL: containerd is not active"; exit 1; }
sudo ctr version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
BK_PID=$(cat "$RUN_DIR/buildkitd.pid" 2>/dev/null || true)
if [ -z "$BK_PID" ] || [ "$(sudo cat "/proc/$BK_PID/comm" 2>/dev/null)" != "buildkitd" ]; then
    echo "  -> FAIL: the buildkitd that setup started (pid '${BK_PID:-none}') is gone; BuildKit was restarted or stopped"
    exit 1
fi
echo "  -> OK (buildkitd pid $BK_PID)"

echo "[oracle] check 1: the build context must be untouched (Dockerfile.child still"
echo "[oracle]          says FROM $BASE_TAG; no shortcut by editing it)..."
EXPECTED_SHA=$(cat "$STATE_DIR/context.sha256" 2>/dev/null || true)
ACTUAL_SHA=$(cd "$WORK_DIR" 2>/dev/null && sha256sum Dockerfile.base Dockerfile.child base.txt app.txt 2>/dev/null | sha256sum | awk '{print $1}')
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "  -> FAIL: the build context changed or is missing"
    exit 1
fi
BASE_LAYERS=$(cat "$STATE_DIR/base_layers" 2>/dev/null || true)
if [ -z "$BASE_LAYERS" ]; then
    echo "  -> FAIL: setup's recorded base layers are missing"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: $CHILD_TAG must exist in nerdctl's namespace (default)..."
if ! $NERDCTL image inspect "$CHILD_TAG" >/dev/null 2>&1; then
    echo "  -> FAIL: nerdctl does not list $CHILD_TAG"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: the child must really be built ON the local base image: its"
echo "[oracle]          layers = the base image's layers, plus exactly one more"
echo "[oracle]          (the COPY of app.txt)..."
CHILD_LAYERS=$($NERDCTL image inspect "$CHILD_TAG" | python3 -c '
import json, sys
print(" ".join(json.load(sys.stdin)[0]["RootFS"]["Layers"]))
')
RESULT=$(python3 - "$BASE_LAYERS" "$CHILD_LAYERS" <<'PY'
import sys
base, child = sys.argv[1].split(), sys.argv[2].split()
if child[:len(base)] != base:
    print("base layers are not at the bottom of the child (base %d layer(s), child %d layer(s))" % (len(base), len(child)))
elif len(child) != len(base) + 1:
    print("expected exactly %d layers, the child has %d" % (len(base) + 1, len(child)))
else:
    print("ok")
PY
)
if [ "$RESULT" != "ok" ]; then
    echo "  -> FAIL: $RESULT"
    exit 1
fi
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
