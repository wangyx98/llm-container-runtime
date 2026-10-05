#!/bin/bash
set -e

CASE_ID="bench78400979"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
REG_PORT=15078
IMAGE_REF="127.0.0.1:$REG_PORT/$CASE_ID/app:latest"
NS="k8s.io"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BLOBS="$LIB_BASE/io.containerd.content.v1.content/blobs/sha256"
TRIPWIRE_EPOCH=946684800   # 2000-01-01 00:00:00 UTC

digest_of() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$REG_DIR/digests.json" "$1"; }

echo "[precondition] checking the private containerd answers on $SOCK and the work files exist..."
[ -S "$SOCK" ] || { echo "  -> FAIL: $SOCK is not a socket"; exit 1; }
sudo ctr -a "$SOCK" version >/dev/null 2>&1 || { echo "  -> FAIL: containerd does not answer"; exit 1; }
[ -s "$RUN_BASE/containerd.pid" ] || { echo "  -> FAIL: no containerd pid recorded"; exit 1; }
sudo kill -0 "$(cat "$RUN_BASE/containerd.pid")" 2>/dev/null || { echo "  -> FAIL: the recorded containerd is not running"; exit 1; }
[ -s "$STATE_DIR/token" ] || { echo "  -> FAIL: setup did not record the workload token"; exit 1; }
[ -f "$WORK_DIR/proto/runtime/v1/api.proto" ] || { echo "  -> FAIL: the proto files are missing"; exit 1; }
[ -f "$WORK_DIR/proto/containerd/services/images/v1/images.proto" ] || { echo "  -> FAIL: the proto files are missing"; exit 1; }
echo "  -> OK"

echo "[precondition] checking grpcurl is installed..."
grpcurl -version >/dev/null 2>&1 || { echo "  -> FAIL: grpcurl is not installed"; exit 1; }
echo "  -> OK ($(grpcurl -version 2>&1 | head -1))"

# the CRI ImageService really answers (an empty ListImages request over gRPC, no client needed)
echo "[precondition] checking the CRI ImageService of containerd is enabled and answers..."
printf '\x00\x00\x00\x00\x00' | sudo curl -sS --max-time 10 --http2-prior-knowledge --unix-socket "$SOCK" \
    -H 'content-type: application/grpc' -H 'te: trailers' -D "$STATE_DIR/cri.hdr" --data-binary @- \
    "http://localhost/runtime.v1.ImageService/ListImages" -o /dev/null || { echo "  -> FAIL: no answer from the CRI ImageService"; exit 1; }
if ! tr -d '\r' < "$STATE_DIR/cri.hdr" | grep -qi '^grpc-status: *0$'; then
    echo "  -> FAIL: the CRI ImageService does not answer ListImages with status 0"
    tr -d '\r' < "$STATE_DIR/cri.hdr" | grep -i '^grpc-' | sed 's/^/     /'
    exit 1
fi
rm -f "$STATE_DIR/cri.hdr"
echo "  -> OK"

echo "[precondition] checking the registry serves the image over plain HTTP..."
MAN_DIGEST=$(digest_of manifest)
GOT=$(curl -sI --max-time 5 "http://127.0.0.1:$REG_PORT/v2/$CASE_ID/app/manifests/latest" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}')
if [ "$GOT" != "$MAN_DIGEST" ]; then
    echo "  -> FAIL: the registry answered '$GOT' instead of $MAN_DIGEST"
    exit 1
fi
echo "  -> OK ($MAN_DIGEST)"

echo "[precondition] checking the symptom: the image is registered in '$NS' but containerd"
echo "[precondition] holds none of its content, and it cannot be started..."
if ! sudo ctr -a "$SOCK" -n "$NS" images ls -q | grep -qxF "$IMAGE_REF"; then
    echo "  -> FAIL: $IMAGE_REF is not registered in $NS"
    exit 1
fi
for what in manifest config layer; do
    h=$(digest_of "$what"); h=${h#sha256:}
    if sudo test -e "$BLOBS/$h"; then
        echo "  -> FAIL: the $what blob is already in the content store"
        exit 1
    fi
done
if sudo grep -q ' /v2/.*/blobs/' "$REG_DIR/requests.log"; then
    echo "  -> FAIL: something already downloaded blobs from the registry"
    exit 1
fi
OUT=$(timeout 60 sudo ctr -a "$SOCK" -n "$NS" run --rm "$IMAGE_REF" "$CASE_ID-pre" 2>&1) && RC=0 || RC=$?
if [ "$RC" -eq 0 ] || echo "$OUT" | grep -q "$(cat "$STATE_DIR/token")"; then
    echo "  -> FAIL: the image starts although none of its content is there"
    exit 1
fi
echo "  -> OK (starting it fails: $(echo "$OUT" | tail -1 | cut -c1-110))"

# --- tripwire: detect that a forbidden client (ctr, nerdctl, crictl) was run ---
# Running a binary updates its access time. The binaries' atime is set far in the past now and
# oracle.sh reads it back first thing: a newer value means the binary was executed. Merely
# looking for it (command -v, ls, stat) does not touch the atime. This must be the LAST step,
# nothing here or between this script and the solution may run ctr again.
echo "[precondition] arming the check that detects use of ctr, nerdctl and crictl..."
BINS=()
for b in ctr nerdctl crictl; do
    for p in $(command -v "$b" 2>/dev/null; sudo bash -c "command -v $b" 2>/dev/null); do
        r=$(readlink -f "$p")
        [ -f "$r" ] && BINS+=("$r")
    done
done
BINS=($(printf '%s\n' "${BINS[@]}" | sort -u))
printf '%s\n' "${BINS[@]}" > "$STATE_DIR/tripwire_bins"

TRIPWIRE_OK=1
# self-test with ctr itself: set its atime back, make sure it reads back, run ctr, see it move
CTR_REAL=$(readlink -f "$(command -v ctr)")
sudo touch -a -d "@$TRIPWIRE_EPOCH" "$CTR_REAL"
[ "$(sudo stat -c %X "$CTR_REAL")" = "$TRIPWIRE_EPOCH" ] || TRIPWIRE_OK=0
if [ "$TRIPWIRE_OK" = 1 ]; then
    sudo ctr --version >/dev/null 2>&1 || true
    [ "$(sudo stat -c %X "$CTR_REAL")" != "$TRIPWIRE_EPOCH" ] || TRIPWIRE_OK=0
fi
if [ "$TRIPWIRE_OK" = 1 ]; then
    for b in "${BINS[@]}"; do
        sudo touch -a -d "@$TRIPWIRE_EPOCH" "$b"
        [ "$(sudo stat -c %X "$b")" = "$TRIPWIRE_EPOCH" ] || TRIPWIRE_OK=0
    done
fi
echo "$TRIPWIRE_OK" > "$STATE_DIR/tripwire_ok"
if [ "$TRIPWIRE_OK" = 1 ]; then
    echo "  -> OK (watching: ${BINS[*]})"
else
    echo "  -> WARNING: this file system does not record access times (noatime?); the oracle will not be able to tell whether ctr was used"
fi

echo "[precondition] all conditions met."
