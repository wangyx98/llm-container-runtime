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
# config digest and diff ids of the image whose manifest digest is $1, as containerd stores them
image_ids() {
    local man cfg
    man=$($CTR content get "$1" 2>/dev/null) || return 1
    cfg=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["config"]["digest"])' <<<"$man") || return 1
    echo "$cfg"
    $CTR content get "$cfg" 2>/dev/null | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["rootfs"]["diff_ids"]))'
}

echo "[oracle] check 1: both daemons must be the very processes of the setup (a restarted or"
echo "[oracle]          reconfigured daemon proves nothing) and Docker must still use its own store..."
alive_same containerd && $CTR version >/dev/null 2>&1 || { echo "  -> FAIL: the containerd of this task was restarted, stopped or replaced"; exit 1; }
alive_same dockerd && $DOCKER info >/dev/null 2>&1 || { echo "  -> FAIL: the dockerd of this task was restarted, stopped or replaced"; exit 1; }
if $DOCKER info --format '{{json .DriverStatus}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'; then
    echo "  -> FAIL: Docker was switched to the containerd image store"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: the image must still be in Docker, unchanged (same ID, same layer) and run there..."
ID=$($DOCKER image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
if [ -z "$ID" ]; then
    echo "  -> FAIL: Docker no longer has $IMAGE: sharing does not mean moving"
    exit 1
fi
if [ "$ID" != "$(truth config)" ] || [ "$($DOCKER image inspect "$IMAGE" --format '{{index .RootFS.Layers 0}}' 2>/dev/null)" != "$(truth diff_id)" ]; then
    echo "  -> FAIL: the image in Docker was changed"
    exit 1
fi
TOKEN=$(sudo cat "$STATE_DIR/token")
OUT=$(timeout -k 5 60 sudo docker -H "unix://$DOCKER_SOCK" run --rm --pull never --network none "$IMAGE" </dev/null 2>/dev/null || true)
[ "$OUT" = "$TOKEN" ] || { echo "  -> FAIL: the image in Docker no longer prints its marker"; exit 1; }
echo "  -> OK"

echo "[oracle] check 3: containerd must hold the very same image under the name $IMAGE, in its"
echo "[oracle]          default namespace: same config digest, same layer (diff id), content complete..."
MAN=$($CTR images ls 2>/dev/null | awk -v r="$IMAGE" '$1==r{print $3}')
if [ -z "$MAN" ]; then
    # present under another name?
    for m in $($CTR images ls 2>/dev/null | awk 'NR>1{print $3}'); do
        if [ "$(image_ids "$m" | head -1)" = "$(truth config)" ]; then
            echo "  -> FAIL: containerd has the image but not under the name $IMAGE (see 'ctr images ls')"
            exit 1
        fi
    done
    if [ -n "$($CTR -n moby images ls -q 2>/dev/null)" ]; then
        echo "  -> FAIL: the image is not in the default namespace of containerd (the one 'ctr images ls' shows)"
        exit 1
    fi
    echo "  -> FAIL: containerd has no image named $IMAGE in its default namespace"
    exit 1
fi
IDS=$(image_ids "$MAN") || { echo "  -> FAIL: the content of the image in containerd is not readable"; exit 1; }
CFG=$(echo "$IDS" | sed -n 1p)
LAYERS=$(echo "$IDS" | sed -n 2p)
if [ "$CFG" != "$(truth config)" ]; then
    echo "  -> FAIL: the image in containerd has config digest $CFG: it is a different image"
    exit 1
fi
if [ "$LAYERS" != "$(truth diff_id)" ]; then
    echo "  -> FAIL: the layers of the image in containerd are not those of the Docker image"
    exit 1
fi
if ! $CTR images check 2>/dev/null | awk -v r="$IMAGE" '$1==r' | grep -q "complete"; then
    echo "  -> FAIL: the content of the image in containerd is not complete"
    exit 1
fi
echo "  -> OK (config $CFG)"

echo "[oracle] check 4: ctr must run the image from containerd's store and print the marker..."
# stdin from /dev/null: ctr run copies its stdin into the container, and under `timeout` (own process group)
# a terminal stdin stops it with SIGTTIN when the script is run by hand; -k: kill it if TERM is not enough
OUT=$(timeout -k 5 60 sudo ctr -a "$CTD_SOCK" run --rm "$IMAGE" "$CASE_ID-oracle" </dev/null 2>/dev/null) || {
    echo "  -> FAIL: ctr run failed"
    exit 1
}
if [ "$OUT" != "$TOKEN" ]; then
    echo "  -> FAIL: the container printed '$OUT', not the marker of the image"
    exit 1
fi
echo "  -> OK (marker read inside the container run by ctr)"
echo "[oracle] all checks passed."
