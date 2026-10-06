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
TRIPWIRE_EPOCH=946684800

# This check has to come before anything below runs ctr itself.
echo "[oracle] check 0: ctr, nerdctl and crictl must not have been run by the solution..."
if [ "$(cat "$STATE_DIR/tripwire_ok" 2>/dev/null)" = 1 ]; then
    while read -r b; do
        [ -n "$b" ] || continue
        AT=$(sudo stat -c %X "$b" 2>/dev/null || echo "$TRIPWIRE_EPOCH")
        if [ "$AT" != "$TRIPWIRE_EPOCH" ]; then
            echo "  -> FAIL: $b was run (the task rules out ctr, nerdctl and crictl)"
            exit 1
        fi
    done < "$STATE_DIR/tripwire_bins"
    echo "  -> OK"
else
    echo "  -> skipped (access times are not recorded on this machine)"
fi

digest_of() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$REG_DIR/digests.json" "$1"; }
CTR="sudo ctr -a $SOCK"

echo "[oracle] check 1: the private containerd must be the same process as before and answer,"
echo "[oracle]          and the registry must still be up..."
if ! sudo kill -0 "$(cat "$RUN_BASE/containerd.pid" 2>/dev/null)" 2>/dev/null || ! $CTR version >/dev/null 2>&1; then
    echo "  -> FAIL: the containerd of this task is not running (it was stopped or replaced)"
    exit 1
fi
if ! curl -sf --max-time 5 "http://127.0.0.1:$REG_PORT/v2/" >/dev/null; then
    echo "  -> FAIL: the registry does not answer"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: $IMAGE_REF must be an image of the '$NS' namespace and its record must"
echo "[oracle]          point at the manifest the registry serves..."
MAN_DIGEST=$(digest_of manifest)
LINE=$($CTR -n "$NS" images ls "name==$IMAGE_REF" | awk -v r="$IMAGE_REF" '$1==r')
if [ -z "$LINE" ]; then
    echo "  -> FAIL: $IMAGE_REF is not an image of the $NS namespace"
    exit 1
fi
if ! echo "$LINE" | grep -qF "$MAN_DIGEST"; then
    echo "  -> FAIL: the image record points at another digest: $(echo "$LINE" | awk '{print $3}') (the registry serves $MAN_DIGEST)"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: the content must really be in containerd's content store, read straight"
echo "[oracle]          from its files: manifest, config and layer blob present, each with the"
echo "[oracle]          size the manifest states and a sha256 equal to its digest..."
for what in manifest config layer; do
    d=$(digest_of "$what"); h=${d#sha256:}
    size=$(digest_of "${what}_size")
    if ! sudo test -f "$BLOBS/$h"; then
        echo "  -> FAIL: the $what blob $d is not in the content store (only the image's metadata record exists)"
        exit 1
    fi
    got_size=$(sudo stat -c %s "$BLOBS/$h")
    got_hash=$(sudo sha256sum "$BLOBS/$h" | cut -d' ' -f1)
    if [ "$got_size" != "$size" ] || [ "$got_hash" != "$h" ]; then
        echo "  -> FAIL: the $what blob is damaged or incomplete (size $got_size of $size, sha256 $got_hash)"
        exit 1
    fi
done
echo "  -> OK (3 blobs, sizes and digests verified)"

echo "[oracle] check 4: containerd must have downloaded that content from the local registry"
echo "[oracle]          itself (a manifest request and a request for the config and for the layer,"
echo "[oracle]          with containerd's User-Agent, in the registry's request log)..."
sudo cat "$REG_DIR/requests.log" > "$STATE_DIR/requests.log"
for what in config layer; do
    d=$(digest_of "$what")
    if ! grep -E "^GET /v2/.*/blobs/$d " "$STATE_DIR/requests.log" | grep -qi 'ua=containerd'; then
        echo "  -> FAIL: containerd never downloaded the $what blob $d from the registry"
        exit 1
    fi
done
if ! grep -E "^(GET|HEAD) /v2/.*/manifests/" "$STATE_DIR/requests.log" | grep -qi 'ua=containerd'; then
    echo "  -> FAIL: containerd never asked the registry for the manifest"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 5: a new container started from $IMAGE_REF must run its default command"
echo "[oracle]          and print this run's token (it exists only inside the image)..."
TOKEN=$(cat "$STATE_DIR/token")
OUT=$(timeout -k 5 90 sudo ctr -a "$SOCK" -n "$NS" run --rm "$IMAGE_REF" "$CASE_ID-oracle" </dev/null 2>&1) && RC=0 || RC=$?
if [ "$RC" -ne 0 ]; then
    echo "  -> FAIL: the container did not run (exit $RC): $(echo "$OUT" | tail -2 | tr '\n' ' ' | cut -c1-200)"
    exit 1
fi
if ! echo "$OUT" | grep -qF "$CASE_ID-workload-ok token=$TOKEN"; then
    echo "  -> FAIL: the container did not print this image's line: $(echo "$OUT" | tail -2 | tr '\n' ' ' | cut -c1-200)"
    exit 1
fi
echo "  -> OK"
echo "[oracle] all checks passed."
