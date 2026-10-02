#!/bin/bash
set -e

CTD_SOCK="/run/containerd/containerd.sock"
BK_SOCK="/run/buildkit/buildkitd.sock"
CASE_ID="bench71709053"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BASE_TAG="$CASE_ID-base:local"
CHILD_TAG="$CASE_ID-child:local"

NERDCTL="sudo nerdctl --address unix://$CTD_SOCK --namespace default"

echo "[precondition] checking containerd and BuildKit are up..."
sudo systemctl is-active --quiet containerd
sudo ctr version >/dev/null
sudo buildctl --addr "unix://$BK_SOCK" debug workers >/dev/null
echo "  -> OK"

echo "[precondition] checking the build context is exactly as setup wrote it..."
for f in Dockerfile.base Dockerfile.child base.txt app.txt; do
    [ -s "$WORK_DIR/$f" ] || { echo "  -> FAIL: $WORK_DIR/$f is missing"; exit 1; }
done
EXPECTED_SHA=$(cat "$STATE_DIR/context.sha256" 2>/dev/null || true)
ACTUAL_SHA=$(cd "$WORK_DIR" && sha256sum Dockerfile.base Dockerfile.child base.txt app.txt | sha256sum | awk '{print $1}')
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "  -> FAIL: the build context differs from what setup recorded"
    exit 1
fi
if ! grep -qx "FROM $BASE_TAG" "$WORK_DIR/Dockerfile.child"; then
    echo "  -> FAIL: Dockerfile.child does not start FROM $BASE_TAG"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the base image exists for nerdctl (namespace default),"
echo "[precondition] with exactly the layers setup recorded..."
BASE_LAYERS=$(cat "$STATE_DIR/base_layers" 2>/dev/null || true)
NOW_LAYERS=$($NERDCTL image inspect "$BASE_TAG" 2>/dev/null | python3 -c '
import json, sys
print(" ".join(json.load(sys.stdin)[0]["RootFS"]["Layers"]))
' 2>/dev/null || true)
if [ -z "$BASE_LAYERS" ] || [ "$BASE_LAYERS" != "$NOW_LAYERS" ]; then
    echo "  -> FAIL: base image missing or changed (recorded '$BASE_LAYERS', found '$NOW_LAYERS')"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking BuildKit's own namespace ('buildkit') does NOT hold it"
echo "[precondition] (that is why the build cannot see it)..."
if sudo ctr -n buildkit images ls -q 2>/dev/null | grep -qF "$CASE_ID"; then
    echo "  -> FAIL: namespace buildkit already holds a $CASE_ID image"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking the child image does not exist yet..."
if $NERDCTL image inspect "$CHILD_TAG" >/dev/null 2>&1; then
    echo "  -> FAIL: $CHILD_TAG already exists"
    exit 1
fi
echo "  -> OK"

echo "[precondition] reproducing the symptom: building the child image must fail..."
if ( cd "$WORK_DIR" && timeout 120 $NERDCTL build -t "$CHILD_TAG" -f Dockerfile.child . ) >"$STATE_DIR/precondition_build.out" 2>&1; then
    echo "  -> FAIL: the child build succeeded; the environment is not broken"
    exit 1
fi
if $NERDCTL image inspect "$CHILD_TAG" >/dev/null 2>&1; then
    echo "  -> FAIL: the failed build still left a child image behind"
    exit 1
fi
grep -E "^error:" "$STATE_DIR/precondition_build.out" | head -2 | sed 's/^/  -> /'
echo "  -> OK (the build fails as in the bug report)"

echo "[precondition] PASS - the base image is there for nerdctl, the child build"
echo "[precondition]        cannot find it."
