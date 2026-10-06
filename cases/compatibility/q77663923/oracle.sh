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
truth() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/image.truth" "$1"; }

echo "[oracle] check 1: both daemons must be the very processes of the setup (a restarted or"
echo "[oracle]          reconfigured daemon proves nothing) and Docker must still use its own store..."
alive_same containerd && $CTR version >/dev/null 2>&1 || { echo "  -> FAIL: the containerd of this task was restarted, stopped or replaced"; exit 1; }
alive_same dockerd && $DOCKER info >/dev/null 2>&1 || { echo "  -> FAIL: the dockerd of this task was restarted, stopped or replaced"; exit 1; }
if $DOCKER info --format '{{json .DriverStatus}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'; then
    echo "  -> FAIL: Docker was switched to the containerd image store"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: the image must still be in ctr, unchanged..."
$CTR images ls 2>/dev/null | awk -v r="$IMAGE" '$1==r' | grep -q "$(truth manifest)" || { echo "  -> FAIL: ctr no longer holds $IMAGE with the original digest"; exit 1; }
echo "  -> OK"

echo "[oracle] check 3: Docker must hold the very same image: same image ID (the digest of the"
echo "[oracle]          config), same layer, same entrypoint, under the name $IMAGE..."
ID=$($DOCKER image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
if [ -z "$ID" ]; then
    echo "  -> FAIL: Docker has no image named $IMAGE"
    exit 1
fi
if [ "$ID" != "$(truth config)" ]; then
    echo "  -> FAIL: the image in Docker has ID $ID, not the config digest of the ctr image: it is a different image"
    exit 1
fi
NL=$($DOCKER image inspect "$IMAGE" --format '{{len .RootFS.Layers}}' 2>/dev/null || echo 0)
L0=$($DOCKER image inspect "$IMAGE" --format '{{index .RootFS.Layers 0}}' 2>/dev/null || true)
if [ "$NL" != "1" ] || [ "$L0" != "$(truth diff_id)" ]; then
    echo "  -> FAIL: the layers of the image in Docker are not those of the ctr image ($NL layer(s), first $L0)"
    exit 1
fi
EP=$($DOCKER image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}' 2>/dev/null || true)
if [ "$EP" != '["/show"]' ]; then
    echo "  -> FAIL: the entrypoint of the image in Docker is $EP, not the one of the ctr image"
    exit 1
fi
echo "  -> OK (ID $ID)"

echo "[oracle] check 4: Docker must run the image offline (no pull allowed) and print the marker..."
TOKEN=$(sudo cat "$STATE_DIR/token")
OUT=$(timeout 60 sudo docker -H "unix://$DOCKER_SOCK" run --rm --pull never --network none "$IMAGE" 2>/dev/null) || {
    echo "  -> FAIL: docker run --pull never failed"
    exit 1
}
if [ "$OUT" != "$TOKEN" ]; then
    echo "  -> FAIL: the container printed '$OUT', not the marker of the image"
    exit 1
fi
echo "  -> OK (marker read inside the container run by Docker)"
echo "[oracle] all checks passed."
