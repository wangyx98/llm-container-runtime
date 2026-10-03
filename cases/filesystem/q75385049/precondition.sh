#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75385049"
NS="$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
TARBALL="$WORK_DIR/hello.tar"
IMAGE_REF="docker.io/library/bench75385049-hello:latest"

echo "[precondition] checking containerd is up and ctr can talk to it..."
sudo systemctl is-active --quiet containerd
sudo ctr version >/dev/null
echo "  -> OK"

echo "[precondition] checking the archive is the docker-archive setup wrote: one image,"
echo "[precondition] and its manifest.json names no image (RepoTags is empty)..."
[ -s "$TARBALL" ] || { echo "  -> FAIL: $TARBALL does not exist"; exit 1; }
IMAGE_ID=$(cat "$STATE_DIR/image_id")
tar -xOf "$TARBALL" manifest.json | python3 -c '
import json, sys
m = json.load(sys.stdin)
if len(m) != 1:
    sys.exit("manifest.json lists %d images, expected 1" % len(m))
if m[0].get("RepoTags"):
    sys.exit("RepoTags is not empty: %r" % (m[0]["RepoTags"],))
if m[0]["Config"] != "'"$IMAGE_ID"'.json":
    sys.exit("config is %s, setup recorded %s.json" % (m[0]["Config"], "'"$IMAGE_ID"'"))
' || { echo "  -> FAIL: the archive is not as setup left it"; exit 1; }
echo "  -> OK (image id sha256:$IMAGE_ID)"

echo "[precondition] checking containerd has no such image yet, in any namespace..."
for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
    if sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -qF "$CASE_ID"; then
        echo "  -> FAIL: namespace '$ns' already has an image named like this case's"
        exit 1
    fi
done
echo "  -> OK"

echo "[precondition] checking the symptom itself: a plain 'ctr images import' of the"
echo "[precondition] archive succeeds without a word, and 'ctr images ls' stays empty..."
OUT=$(sudo ctr -n "$NS" images import "$TARBALL" 2>&1) && RC=0 || RC=$?
if [ "$RC" -ne 0 ]; then
    echo "  -> FAIL: the plain import failed (exit $RC): $OUT"
    exit 1
fi
LISTED=$(sudo ctr -n "$NS" images ls -q 2>/dev/null | grep -v '^$' || true)
if [ -n "$LISTED" ]; then
    echo "  -> FAIL: the plain import already created image(s): $LISTED"
    exit 1
fi
echo "  -> OK (import exit 0, 'ctr -n $NS images ls' is empty)"

echo "[precondition] all checks passed."
