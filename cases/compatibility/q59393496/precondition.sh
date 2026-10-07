#!/bin/bash
set -e

CASE_ID="bench59393496"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
DOCKER_SOCK="$RUN_BASE/docker.sock"
IMAGE="docker.io/library/$CASE_ID-app:1"
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
for f in containerd.id dockerd.id image.truth token; do
    sudo test -s "$STATE_DIR/$f" || { echo "  -> FAIL: setup did not record $f"; exit 1; }
done
$CTR version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer on $CTD_SOCK"; exit 1; }
$DOCKER info >/dev/null 2>&1 || { echo "  -> FAIL: dockerd does not answer on $DOCKER_SOCK"; exit 1; }
alive_same containerd || { echo "  -> FAIL: the recorded containerd is not running"; exit 1; }
alive_same dockerd || { echo "  -> FAIL: the recorded dockerd is not running"; exit 1; }
echo "  -> OK"

echo "[precondition] checking containerd holds the image, in Docker format, with the digest of setup,"
echo "[precondition] and that it has no container and no task (in the namespaces default and moby)..."
LINE=$($CTR images ls 2>/dev/null | awk -v r="$IMAGE" '$1==r')
[ -n "$LINE" ] || { echo "  -> FAIL: ctr does not list $IMAGE"; exit 1; }
echo "$LINE" | grep -q "$(truth manifest)" || { echo "  -> FAIL: the digest of the image in ctr is not the one built by setup"; exit 1; }
echo "$LINE" | grep -q 'application/vnd.docker.distribution.manifest.v2+json' \
    || { echo "  -> FAIL: the image is not a Docker format image"; exit 1; }
for ns in default moby; do
    if [ -n "$(sudo ctr -a "$CTD_SOCK" -n "$ns" containers ls -q 2>/dev/null)" ] \
       || [ -n "$(sudo ctr -a "$CTD_SOCK" -n "$ns" tasks ls -q 2>/dev/null)" ]; then
        echo "  -> FAIL: there is already a container or a task in the namespace $ns"
        exit 1
    fi
done
[ -z "$(ls -A "$WORK_DIR/out" 2>/dev/null)" ] || { echo "  -> FAIL: the output directory is not empty"; exit 1; }
echo "  -> OK"

echo "[precondition] checking the image runs with ctr and the program writes the expected line and exits 17"
echo "[precondition] (a throw-away container with --rm and a scratch directory, nothing is left behind)..."
TOKEN=$(sudo cat "$STATE_DIR/token")
PRE_OUT="$STATE_DIR/pre-out"
mkdir -p "$PRE_OUT"; chmod 0777 "$PRE_OUT"
set +e
timeout -k 5 60 $CTR run --rm --env BENCH_MSG=hello-from-ctr \
    --mount "type=bind,src=$PRE_OUT,dst=/out,options=rbind:rw" "$IMAGE" "$CASE_ID-pre" /app ping </dev/null >/dev/null 2>&1
RC=$?
set -e
[ "$RC" = "17" ] || { echo "  -> FAIL: the throw-away container exited with $RC, not 17"; exit 1; }
[ "$(sudo cat "$PRE_OUT/result.txt" 2>/dev/null)" = "$TOKEN|msg=hello-from-ctr|arg=ping|argv0=/app" ] \
    || { echo "  -> FAIL: the line written by the program is not the expected one"; exit 1; }
sudo rm -rf "$PRE_OUT"
if [ -n "$($CTR containers ls -q 2>/dev/null)" ]; then
    echo "  -> FAIL: the throw-away container was not removed"
    exit 1
fi
echo "  -> OK"

echo "[precondition] checking Docker does not have the image (it would have to be loaded from ctr)..."
if [ -n "$($DOCKER images -q 2>/dev/null)" ]; then
    echo "  -> FAIL: Docker already has an image"
    exit 1
fi
echo "  -> OK"

echo "[precondition] all conditions met."
