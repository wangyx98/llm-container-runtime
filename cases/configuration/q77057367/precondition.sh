#!/bin/bash
set -e

CASE_ID="bench77057367"
RUN_BASE="/run/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
REG_DIR="$RUN_BASE/registry"
REG="http://127.0.0.1:18077"
REPO="e2eteam/busybox"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

CTR="sudo ctr -a $CTD_SOCK"
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
fail() { echo "  -> FAIL: $*"; exit 1; }
jget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/$1.truth" "$2"; }

echo "[precondition] checking the state setup recorded and the two daemons (containerd, registry)..."
for f in containerd.id registry.id new.truth old.truth token.new token.old registry.state0; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
for d in containerd registry; do alive_same "$d" || fail "the recorded $d is not running"; done
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $CTD_SOCK"
echo "  -> OK"

echo "[precondition] checking the registry (plain HTTP on 127.0.0.1:18077) serves $REPO:1.29 and $REPO:1.28 with the recorded digests..."
for t in new:1.29 old:1.28; do
    w=${t%%:*}; tag=${t##*:}
    HDR=$(curl -sI --max-time 5 -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$REG/v2/$REPO/manifests/$tag" | tr -d '\r')
    echo "$HDR" | head -1 | grep -q ' 200' || fail "the registry does not serve $REPO:$tag"
    [ "$(echo "$HDR" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')" = "$(jget $w manifest)" ] || fail "the digest of $REPO:$tag is not the recorded one"
done
[ "$(jget new manifest)" != "$(jget old manifest)" ] || fail "the two images have the same digest"
echo "  -> OK"

echo "[precondition] checking containerd (namespace default) holds only the older image, and nothing of $REPO:1.29..."
REFS=$($CTR images ls -q 2>/dev/null)
echo "$REFS" | grep -qx "127.0.0.1:18077/$REPO:1.28" || fail "the older image is not in containerd"
if echo "$REFS" | grep -q ":1\.29"; then fail "an image 1.29 is already in containerd"; fi
if $CTR content ls -q 2>/dev/null | grep -qF "$(jget new layer)"; then fail "the layer of $REPO:1.29 is already in containerd"; fi
echo "  -> OK"

echo "[precondition] checking the engineer's command fails: ctr images pull $REPO:1.29 (no registry in the name)..."
if timeout 90 $CTR images pull "$REPO:1.29" > "$WORK_DIR/pre_out.txt" 2> "$WORK_DIR/pre_err.txt"; then
    fail "the pull of the short name succeeded before any fix was applied"
fi
grep -q 'https://e2eteam/v2/busybox/manifests/1.29' "$WORK_DIR/pre_err.txt" \
    || fail "the pull failed, but not by taking 'e2eteam' as the registry host: $(grep -v DEPRECATION "$WORK_DIR/pre_err.txt" | tail -1 | cut -c1-200)"
if sudo grep -q "ua=containerd/" "$REG_DIR/requests.log" && sudo grep "ua=containerd/" "$REG_DIR/requests.log" | grep -qF "$(jget new manifest)"; then
    fail "the registry saw containerd fetch $REPO:1.29"
fi
echo "  -> OK ($(grep -o 'Head [^:]*:[^:]*' "$WORK_DIR/pre_err.txt" | head -1 | cut -c1-100))"

echo "[precondition] PASS - the short name resolves to a host called e2eteam; $REPO:1.29 is not in containerd."
