#!/bin/bash
set -e

CASE_ID="bench68660550"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
DATA_DIR="$WORK_DIR/data"
H="$CASE_ID.local"
POD_NAME="$CASE_ID-pod"
LIVE_NAME="$CASE_ID-live"
JOB_NAME="$CASE_ID-job"
WEB_REF="$H/foo-web:1";   WEB_ALIAS="$H/live-alias:stable"
BATCH_REF="$H/bar-batch:1"
FOOOLD_REF="$H/foo-old:1"
BAROLD_REF="$H/bar-old:1"
PINNED_REF="$H/foo-pinned:1"; PIN_ALIAS="$H/release-pin:1"
CACHE_REF="$H/web-cache:1"
PAUSE_REF="$H/pause:1"

CTR="sudo ctr -a $CTD_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$CTD_SOCK" --image-endpoint "unix://$CTD_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
imgid() { "${CRI[@]}" inspecti -o go-template --template '{{.status.id}}' "$1" 2>/dev/null; }   # image ID by name or ID, '' if unknown
refs() { $CTR -n k8s.io images ls -q 2>/dev/null; }                                          # every image record of the k8s.io namespace

echo "[precondition] checking the node's containerd (the process of setup) and its CRI..."
for f in containerd.id pod_id container_live container_job pid starttime nonce containerdctl.sha \
         image_id_web image_id_batch image_id_fooold image_id_barold image_id_pinned image_id_cache; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same containerd || fail "the recorded containerd is not running"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the workload runs (same pid, heartbeat counter growing), its pod is ready, and the one-shot"
echo "[precondition] container has exited..."
LIVE=$(st container_live); JOB=$(st container_job); POD=$(st pod_id)
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$LIVE" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the workload is not running"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$JOB" 2>/dev/null)" = "CONTAINER_EXITED" ] || fail "the one-shot container has not exited"
[ "$("${CRI[@]}" inspectp -o go-template --template '{{.status.state}}' "$POD" 2>/dev/null)" = "SANDBOX_READY" ] || fail "the pod is not ready"
C1=$(sed -n 's/^counter=//p' "$DATA_DIR/status"); sleep 2; C2=$(sed -n 's/^counter=//p' "$DATA_DIR/status")
[ -n "$C1" ] && [ "$C2" -gt "$C1" ] || fail "the heartbeat counter does not grow ($C1 -> $C2)"
echo "  -> OK (counter $C1 -> $C2)"

echo "[precondition] checking the images: what the filter of the question ('foo|bar') matches, who uses it, and the aliases..."
"${CRI[@]}" images 2>/dev/null | sed 's/^/     /'
MATCHED=$("${CRI[@]}" images 2>/dev/null | grep -E -- 'foo|bar' | awk '{print $1":"$2}')
for r in "$WEB_REF" "$BATCH_REF" "$FOOOLD_REF" "$BAROLD_REF" "$PINNED_REF"; do
    echo "$MATCHED" | grep -qxF "$r" || fail "the filter does not list $r"
done
for r in "$CACHE_REF" "$PIN_ALIAS" "$WEB_ALIAS"; do
    if echo "$MATCHED" | grep -qxF "$r"; then fail "the filter lists $r, which does not match 'foo|bar'"; fi
done
[ "$(imgid "$WEB_REF")" = "sha256:$(st image_id_web)" ] || fail "foo-web:1 is not the recorded image"
[ "$(imgid "$WEB_ALIAS")" = "sha256:$(st image_id_web)" ] || fail "live-alias:stable is not a second name of the workload's image"
[ "$(imgid "$PINNED_REF")" = "sha256:$(st image_id_pinned)" ] || fail "foo-pinned:1 is not the recorded image"
[ "$(imgid "$PIN_ALIAS")" = "sha256:$(st image_id_pinned)" ] || fail "release-pin:1 is not a second name of foo-pinned:1's image"
echo "  -> OK"

echo "[precondition] checking which images containers use (running and exited ones both count as users)..."
USED=$("${CRI[@]}" ps -a -o json 2>/dev/null | python3 -c 'import json,sys; print("\n".join(sorted({c["imageRef"] for c in json.load(sys.stdin)["containers"]})))')
echo "$USED" | sed 's/^/     used: /' | cut -c1-40
[ "$(echo "$USED" | grep -c .)" = "2" ] || fail "expected exactly two images in use"
echo "$USED" | grep -qxF "sha256:$(st image_id_web)" || fail "the workload's image is not in use"
echo "$USED" | grep -qxF "sha256:$(st image_id_batch)" || fail "the one-shot container's image is not in use"
for k in fooold barold pinned cache; do
    if echo "$USED" | grep -qxF "sha256:$(st image_id_$k)"; then fail "image $k is used by a container"; fi
done
echo "  -> OK"

echo "[precondition] PASS - the filter 'foo|bar' lists images that containers use (foo-web runs, bar-batch has an exited container), idle ones,"
echo "[precondition]        and an idle image that has a second name the filter does not match."
