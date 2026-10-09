#!/bin/bash
set -e

CASE_ID="bench74546773"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
VOL_DIR="$WORK_DIR/volume-path/mount"
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"
DUMP_PATH="/var/dump/app.hprof"

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
lastlog() { "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | tail -1; }      # the newest line the workload printed
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"; }                         # field of such a line

echo "[precondition] checking the node's containerd (the process of setup) and its CRI..."
for f in containerd.id pod_id container_app pid starttime dump.sha256 dump.size src.stat beat0 containerdctl.sha; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same containerd || fail "the recorded containerd is not running"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking the workload runs (the recorded host pid and start time) and its heartbeat counts..."
APP_ID=$(st container_app); PID=$(st pid)
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "the workload is not running"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || fail "the workload has another host pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')" = "$(st starttime)" ] || fail "the workload process has another start time"
L1=$(lastlog); sleep 2; L2=$(lastlog)
[ "$(field beat "$L2")" -gt "$(field beat "$L1")" ] || fail "the heartbeat does not advance ($L1 / $L2)"
[ "$(field pid "$L2")" = "1" ] || fail "the workload is not pid 1 in its own pid namespace"
echo "  -> OK ($L2)"

echo "[precondition] checking the dump exists only in the container's own writable filesystem: it has the recorded size and sha256 there,"
echo "[precondition] the pod's volume (what the node shows: vold_data.json and an empty mount directory) does not hold it, and no tool that"
echo "[precondition] could read it from inside the container (cat, tar, cp, sh) is in the image..."
SRC="/proc/$PID/root$DUMP_PATH"
[ "$(sudo stat -c %s "$SRC")" = "$(st dump.size)" ] || fail "the dump has not the recorded size"
[ "$(sudo sha256sum "$SRC" | awk '{print $1}')" = "$(st dump.sha256)" ] || fail "the dump's sha256 is not the recorded one"
[ -z "$(ls -A "$VOL_DIR")" ] || fail "the pod's volume directory is not empty"
[ -f "$WORK_DIR/volume-path/vold_data.json" ] || fail "the volume's vold_data.json is missing"
if sudo find "$WORK_DIR" -xdev -name 'app.hprof*' -not -path '*/.bench/*' 2>/dev/null | grep -q .; then fail "a copy of the dump already sits under $WORK_DIR"; fi
for t in cat tar cp sh; do
    if "${CRI[@]}" exec "$APP_ID" "/bin/$t" --version >/dev/null 2>&1; then fail "the container has /bin/$t"; fi
done
OUT=$("${CRI[@]}" exec "$APP_ID" cat "$DUMP_PATH" 2>&1 >/dev/null || true)
echo "     crictl exec cat inside the container: $(echo "$OUT" | head -1 | cut -c1-110)"
[ -n "$OUT" ] || fail "'crictl exec <app> cat' works: the dump could be read from inside"
echo "  -> OK"

echo "[precondition] PASS - a $(st dump.size) byte dump with a known sha256 sits in the writable layer of the running workload, not in its volume,"
echo "[precondition]        and cannot be read by a command run inside the container."
