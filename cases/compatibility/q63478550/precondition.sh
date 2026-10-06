#!/bin/bash
set -e

CASE_ID="bench63478550"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"
IMAGE="registry.invalid/bench63478550/app:1"
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

echo "[precondition] checking the private containerd and the private dockerd answer and are the ones"
echo "[precondition] setup started..."
for f in containerd.id dockerd.id image.truth; do
    [ -s "$STATE_DIR/$f" ] || { echo "  -> FAIL: setup did not record $f"; exit 1; }
done
sudo test -s "$STATE_DIR/token" || { echo "  -> FAIL: setup did not record the token"; exit 1; }
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

echo "[precondition] checking Docker holds the image (the ID is the config digest of the source image,"
echo "[precondition] one layer) and runs it, printing the marker of its file..."
[ "$($DOCKER image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)" = "$(truth config)" ] || { echo "  -> FAIL: Docker does not hold the image with the expected ID"; exit 1; }
[ "$($DOCKER image inspect "$IMAGE" --format '{{index .RootFS.Layers 0}}' 2>/dev/null)" = "$(truth diff_id)" ] || { echo "  -> FAIL: the layer of the image in Docker is not the expected one"; exit 1; }
TOKEN=$(sudo cat "$STATE_DIR/token")
OUT=$(timeout -k 5 60 $DOCKER run --rm --pull never --network none "$IMAGE" </dev/null 2>/dev/null || true)
[ "$OUT" = "$TOKEN" ] || { echo "  -> FAIL: running the image with Docker did not print its marker"; exit 1; }
echo "  -> OK"

echo "[precondition] checking Docker can export it: 'docker save' gives an archive with the layer..."
$DOCKER save "$IMAGE" 2>/dev/null | tar -t 2>/dev/null | grep -q "$(truth diff_id | cut -d: -f2)" || { echo "  -> FAIL: docker save does not give an archive of the image"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the symptom: containerd has no image, in any namespace, ctr cannot run"
echo "[precondition] $IMAGE and cannot pull it (no registry answers for that name)..."
for ns in $($CTR namespaces ls -q 2>/dev/null); do
    if [ -n "$($CTR -n "$ns" images ls -q 2>/dev/null)" ]; then
        echo "  -> FAIL: containerd already has an image in the namespace $ns"
        exit 1
    fi
done
if timeout -k 5 60 $CTR run --rm "$IMAGE" "$CASE_ID-probe" </dev/null >/dev/null 2>&1; then
    echo "  -> FAIL: ctr run worked"
    exit 1
fi
if timeout -k 5 60 $CTR images pull "$IMAGE" </dev/null >/dev/null 2>&1; then
    echo "  -> FAIL: ctr pull worked, a registry answered"
    exit 1
fi
echo "  -> OK"

echo "[precondition] all conditions met."
