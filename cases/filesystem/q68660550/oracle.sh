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

echo "[oracle] check 0: the node's containerd is still the one of setup (not restarted or replaced), its start script is"
echo "[oracle]          unchanged, and its CRI answers..."
alive_same containerd || fail "containerd is not the process of setup (it was restarted or replaced)"
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(st containerdctl.sha)" ] || fail "$CTL_DIR/containerdctl was changed"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
for f in pod_id container_live container_job pid starttime nonce image_id_web image_id_batch image_id_fooold \
         image_id_barold image_id_pinned image_id_cache; do
    [ -n "$(st $f)" ] || fail "setup's recorded $f is missing"
done
ID_WEB="sha256:$(st image_id_web)";       ID_BATCH="sha256:$(st image_id_batch)"
ID_FOOOLD="sha256:$(st image_id_fooold)"; ID_BAROLD="sha256:$(st image_id_barold)"
ID_PINNED="sha256:$(st image_id_pinned)"; ID_CACHE="sha256:$(st image_id_cache)"
echo "  -> OK"

echo "[oracle] check 1: the workload is the same container and process, still running, its heartbeat advances, its pod is"
echo "[oracle]          ready, and the exited one-shot container is still there..."
LIVE=$(st container_live); JOB=$(st container_job); POD=$(st pod_id)
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$LIVE" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the workload container is not running (removed, stopped or recreated)"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$LIVE" 2>/dev/null)" = "$(st pid)" ] || fail "the workload runs under another pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$(st pid)/stat" 2>/dev/null | awk '{print $20}')" = "$(st starttime)" ] || fail "the workload process was restarted (its start time changed)"
[ "$("${CRI[@]}" inspectp -o go-template --template '{{.status.state}}' "$POD" 2>/dev/null)" = "SANDBOX_READY" ] || fail "the pod is not ready"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$JOB" 2>/dev/null)" = "CONTAINER_EXITED" ] || fail "the exited one-shot container $JOB_NAME was removed or restarted"
C1=$(sed -n 's/^counter=//p' "$DATA_DIR/status"); sleep 2; C2=$(sed -n 's/^counter=//p' "$DATA_DIR/status")
[ "$(sed -n 's/^nonce=//p' "$DATA_DIR/status")" = "$(st nonce)" ] || fail "the heartbeat file has another nonce"
[ -n "$C1" ] && [ "$C2" -gt "$C1" ] || fail "the heartbeat counter does not advance ($C1 -> $C2)"
echo "  -> OK (pid $(st pid), counter $C1 -> $C2)"

echo "[oracle] check 2: the images that are in use stay, under all their names: foo-web:1 and its alias live-alias:stable (the"
echo "[oracle]          running workload), bar-batch:1 (the exited container uses it, and that container stays)..."
for r in "$WEB_REF" "$WEB_ALIAS"; do
    [ "$(imgid "$r")" = "$ID_WEB" ] || fail "$r is gone or is another image (the running workload's image must stay)"
done
[ "$(imgid "$BATCH_REF")" = "$ID_BATCH" ] || fail "$BATCH_REF is gone: a container (exited, but still on the node) uses it"
echo "  -> OK"

echo "[oracle] check 3: the images that do not match the filter stay: web-cache:1 (no container, not a foo/bar name) and"
echo "[oracle]          release-pin:1, a second name of the same image as foo-pinned:1..."
[ "$(imgid "$CACHE_REF")" = "$ID_CACHE" ] || fail "$CACHE_REF is gone: it does not match 'foo|bar', a prune of everything unused is not the task"
[ "$(imgid "$PIN_ALIAS")" = "$ID_PINNED" ] || fail "$PIN_ALIAS is gone: it is a name that does not match 'foo|bar', and removing the image by ID or by the other name removes it too"
echo "  -> OK"

echo "[oracle] check 4: the unused images that match the filter are gone: foo-old:1 and bar-old:1 completely (no name, and not even a"
echo "[oracle]          nameless record), and the name foo-pinned:1 (its image stays under release-pin:1)..."
for r in "$FOOOLD_REF" "$BAROLD_REF" "$PINNED_REF"; do
    if refs | grep -qxF "$r"; then fail "$r is still an image name in namespace k8s.io"; fi
    if "${CRI[@]}" images 2>/dev/null | awk '{print $1":"$2}' | grep -qxF "$r"; then fail "the CRI still lists $r"; fi
done
for id in "$ID_FOOOLD" "$ID_BAROLD"; do
    if refs | grep -qxF "$id"; then fail "image $id is still there as a nameless record (removing only the names is not enough)"; fi
    if [ -n "$(imgid "$id")" ]; then fail "the CRI still knows image $id"; fi
done
echo "  -> OK"

echo "[oracle] check 5: nothing else changed in the image store: exactly the kept images and their names remain, and their content"
echo "[oracle]          is complete..."
refs > "$WORK_DIR/oracle_refs.txt"
python3 - "$WORK_DIR/oracle_refs.txt" "$PAUSE_REF" "$(st image_id_pause)" "$WEB_REF" "$WEB_ALIAS" "$BATCH_REF" "$PIN_ALIAS" "$CACHE_REF" \
    "$ID_WEB" "$ID_BATCH" "$ID_PINNED" "$ID_CACHE" <<'PY' || fail "the image store holds other records than the kept ones (see above)"
import sys
got = {l.strip() for l in open(sys.argv[1]) if l.strip()}
pause_ref, pause_id = sys.argv[2], "sha256:" + sys.argv[3]
expect = set(sys.argv[4:])
got -= {pause_ref, pause_id}          # the sandbox image of the pod is not part of the check
if got != expect:
    print("     missing: %s" % sorted(expect - got))
    print("     unexpected: %s" % sorted(got - expect))
    sys.exit(1)
PY
CHK=$($CTR -n k8s.io images check 2>/dev/null)
for r in "$WEB_REF" "$WEB_ALIAS" "$BATCH_REF" "$PIN_ALIAS" "$CACHE_REF"; do
    echo "$CHK" | awk -v r="$r" '$1 == r' | grep -q 'complete' || fail "the content of $r is incomplete (blobs removed)"
done
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
