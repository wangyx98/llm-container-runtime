#!/bin/bash
set -e

CASE_ID="bench77663923"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"
IMAGE="registry.invalid/bench77663923/app:1"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
DOCKER="sudo docker -H unix://$DOCKER_SOCK"
alive_same() {   # $1 = daemon name: still the process recorded by setup (pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}

echo "[precondition] checking the private containerd and the private dockerd answer and are the ones"
echo "[precondition] setup started..."
for f in containerd.id dockerd.id image.truth token; do
    sudo test -s "$STATE_DIR/$f" || { echo "  -> FAIL: setup did not record $f"; exit 1; }
done
$CTR version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer on $CTD_SOCK"; exit 1; }
$DOCKER info >/dev/null 2>&1 || { echo "  -> FAIL: dockerd does not answer on $DOCKER_SOCK"; exit 1; }
alive_same containerd || { echo "  -> FAIL: the recorded containerd is not running"; exit 1; }
alive_same dockerd || { echo "  -> FAIL: the recorded dockerd is not running"; exit 1; }
echo "  -> OK"

echo "[precondition] checking Docker keeps its own, classic image store (the images are not kept in"
echo "[precondition] containerd)..."
if $DOCKER info --format '{{json .DriverStatus}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'; then
    echo "  -> FAIL: this Docker uses the containerd image store"
    exit 1
fi
echo "  -> OK (storage driver $($DOCKER info --format '{{.Driver}}' 2>/dev/null))"

echo "[precondition] checking ctr holds the image, unchanged, and can run it (the marker file is"
echo "[precondition] readable inside it)..."
$CTR images ls -q 2>/dev/null | grep -qx "$IMAGE" || { echo "  -> FAIL: ctr does not list $IMAGE"; exit 1; }
MAN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$STATE_DIR/image.truth")
$CTR images ls 2>/dev/null | awk -v r="$IMAGE" '$1==r' | grep -q "$MAN" || { echo "  -> FAIL: the digest of the image in ctr is not the one built by setup"; exit 1; }
TOKEN=$(sudo cat "$STATE_DIR/token")
OUT=$($CTR run --rm "$IMAGE" "$CASE_ID-probe" 2>/dev/null || true)
[ "$OUT" = "$TOKEN" ] || { echo "  -> FAIL: running the image with ctr did not print its marker"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the symptom: Docker does not have the image, 'docker run' does not find"
echo "[precondition] it and its attempt to pull it fails (no registry answers for that name)..."
if [ -n "$($DOCKER images -q 2>/dev/null)" ] || $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "  -> FAIL: Docker already has an image"
    exit 1
fi
if $DOCKER run --rm --pull never --network none "$IMAGE" >/dev/null 2>&1; then
    echo "  -> FAIL: docker run worked"
    exit 1
fi
if $DOCKER run --rm --pull never --network none "$IMAGE" 2>&1 | grep -qi "no such image"; then :; else
    echo "  -> FAIL: the docker run error is not 'No such image'"
    exit 1
fi
if $DOCKER pull "$IMAGE" >/dev/null 2>&1; then
    echo "  -> FAIL: docker pull worked, a registry answered"
    exit 1
fi
echo "  -> OK"

echo "[precondition] all conditions met."
