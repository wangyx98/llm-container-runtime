#!/bin/bash
set -e

CASE_ID="bench67990326"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
APP_NAME="$CASE_ID-app"
TOOL="$WORK_DIR/cp.sh"
OUT_FILE="$WORK_DIR/out/report.bin"

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
sha() { sudo sha256sum "$1" | awk '{print $1}'; }
size() { sudo stat -c %s "$1"; }
devino() { sudo stat -c '%d:%i' "$1"; }
APP_ID=$(st container_app); PID=$(st pid)
REPORT_SIZE=$(st report.size)
OLD_SHA=$(st report_old.sha256); NEW_SHA=$(st report_new.sha256)
SRC="/proc/$PID/root/data/report.bin"

# the same container, process and heartbeat: not restarted, not recreated, still counting (and a counter that went on from setup's)
identity_ok() {
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || { echo "the container is not running (stopped, removed or recreated)"; return 1; }
    [ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || { echo "the container runs under another host pid"; return 1; }
    [ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')" = "$(st starttime)" ] || { echo "the container process was restarted (its start time changed)"; return 1; }
    local a b
    a=$(field beat "$(lastlog)"); sleep 2; b=$(field beat "$(lastlog)")
    [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] && [ "$a" -gt "$(st beat0)" ] || { echo "the heartbeat does not go on counting ($a -> $b, setup saw $(st beat0))"; return 1; }
    [ "$(field pid "$(lastlog)")" = "1" ] || { echo "the service is not pid 1 any more"; return 1; }
}
# a complete, independent copy: regular file (no symlink, no hard link), other inode than the original, expected size and sha256
copy_ok() {   # $1 = file, $2 = expected size, $3 = expected sha256, $4 = path of the original in the container's root
    [ -f "$1" ] && [ ! -L "$1" ] || { echo "$1 is not a regular file (missing, or a symlink)"; return 1; }
    [ "$(sudo stat -c %h "$1")" = 1 ] || { echo "$1 is a hard link"; return 1; }
    local s h
    s=$(size "$1"); h=$(sha "$1")
    if [ "$h" = "$OLD_SHA" ]; then
        echo "$1 has the content of the report in the IMAGE'S layer (the old one, same size): it was taken from a committed snapshot or a view of it, not from the container's active snapshot"
        return 1
    fi
    [ "$s" = "$2" ] || { echo "$1 has $s bytes, expected $2"; return 1; }
    [ "$h" = "$3" ] || { echo "$1 has not the expected sha256 (${h:0:16}..., expected ${3:0:16}...)"; return 1; }
    [ "$(devino "$1")" != "$(devino "$4")" ] || { echo "$1 is the original file itself (a bind mount), not a copy"; return 1; }
}
# the entry point, as the check uses it: docker cp style CONTAINER:PATH DEST, no terminal, finishing by itself
run_tool() {   # $1 = CONTAINER:PATH, $2 = destination
    local out rc
    out=$(timeout 90 sudo bash "$TOOL" "$1" "$2" </dev/null 2>&1) && rc=0 || rc=$?
    if [ "$rc" != 0 ]; then echo "$TOOL $1 $2 ended with exit code $rc: $(tail -2 <<<"$out" | tr '\n' ' ' | cut -c1-200)"; return 1; fi
}

echo "[oracle] check 0: containerd and the container are still those of setup, the CRI answers, and the entry point $TOOL exists..."
alive_same containerd || fail "containerd is not the process of setup (it was restarted or replaced)"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
for f in containerd.id container_app pid starttime beat0 report.size report_new.sha256 report_old.sha256 src.stat snapkey snapshots.list upperdir lowerdirs mounts.count containers.list images.list; do
    sudo test -s "$STATE_DIR/$f" || fail "setup's recorded $f is missing"
done
MSG=$(identity_ok) || fail "$MSG"
[ -f "$TOOL" ] || fail "the entry point $TOOL does not exist"
echo "  -> OK"

echo "[oracle] check 1: the copy the answer made, $OUT_FILE: a regular file with the size and the SHA-256 of the report in the container (the NEW"
echo "[oracle]          one, from the container's active snapshot), and the original and the image untouched..."
[ "$(sudo stat -c '%i %Y %s' "$SRC" 2>/dev/null)" = "$(st src.stat)" ] || fail "the original report was replaced or modified (inode, modification time or size changed)"
[ "$(sha "$SRC")" = "$NEW_SHA" ] || fail "the original report's content changed"
[ "$(sha "$(st lowerdirs | head -1)/data/report.bin")" = "$OLD_SHA" ] || fail "the report in the image's layer was changed"
MSG=$(copy_ok "$OUT_FILE" "$REPORT_SIZE" "$NEW_SHA" "$SRC") || fail "$MSG"
echo "  -> OK ($OUT_FILE: $REPORT_SIZE bytes, ${NEW_SHA:0:16}...)"

echo "[oracle] check 2: the entry point works again, by the container NAME, to another destination (a directory with a space in its name)..."
mkdir -p "$WORK_DIR/oracle out"
D1="$WORK_DIR/oracle out/r1.bin"
MSG=$(run_tool "$APP_NAME:/data/report.bin" "$D1") || fail "$MSG"
MSG=$(copy_ok "$D1" "$REPORT_SIZE" "$NEW_SHA" "$SRC") || fail "$MSG"
echo "  -> OK"

echo "[oracle] check 3: the application now writes a NEW file and updates the report (a hex number chosen only now: content and size nobody can know"
echo "[oracle]          in advance); the entry point is used for both, the container given by its ID for the new file..."
HEX=$(python3 -c 'import secrets; print("%08x" % secrets.randbits(32))')
"${CRI[@]}" exec "$APP_ID" /app write "$HEX" >/dev/null 2>&1 || fail "the oracle could not make the application write its files"
R=$((16#$HEX))
NEW_FILE_SIZE=$((1048576 + (R & 4095)))
NEW_FILE_SHA=$(python3 "$STATE_DIR/stream.py" hash "$R" "$NEW_FILE_SIZE")
UPD_SHA=$(python3 "$STATE_DIR/stream.py" hash "$((R ^ 25214903917))" "$REPORT_SIZE")
[ "$(sha "$SRC")" = "$UPD_SHA" ] || fail "the oracle's own expectation of the updated report is wrong"
D2="$WORK_DIR/oracle out/new.bin"
MSG=$(run_tool "$APP_ID:/data/new-$HEX" "$D2") || fail "$MSG"
MSG=$(copy_ok "$D2" "$NEW_FILE_SIZE" "$NEW_FILE_SHA" "/proc/$PID/root/data/new-$HEX") || fail "the new file: $MSG"
D3="$WORK_DIR/oracle out/r2.bin"
MSG=$(run_tool "$APP_NAME:/data/report.bin" "$D3") || fail "$MSG"
MSG=$(copy_ok "$D3" "$REPORT_SIZE" "$UPD_SHA" "$SRC") || fail "the updated report: $MSG"
[ "$(sha "$D3")" != "$NEW_SHA" ] || fail "the updated report is the old copy again (a cached or stale copy)"
echo "  -> OK (new-$HEX: $NEW_FILE_SIZE bytes; report.bin updated and fetched again)"

echo "[oracle] check 4: the same container (not stopped, restarted or recreated, heartbeat going on), containerd holding the same containers,"
echo "[oracle]          images and snapshots (no view or other snapshot left behind), and no extra mount of the container's snapshot..."
MSG=$(identity_ok) || fail "$MSG"
alive_same containerd || fail "containerd was replaced meanwhile"
[ "$($CTR -n k8s.io containers ls -q 2>/dev/null | sort)" = "$(st containers.list)" ] || fail "the containers of containerd changed (a container was created or removed)"
[ "$($CTR -n k8s.io images ls 2>/dev/null | awk 'NR>1 {print $1, $3}' | sort)" = "$(st images.list)" ] || fail "the images of containerd changed"
NOW=$($CTR -n k8s.io snapshots ls 2>/dev/null | awk 'NR>1 {print $1, $2, $3}' | sort)
[ "$NOW" = "$(st snapshots.list)" ] || fail "the snapshots of containerd changed (left behind: $(comm -13 <(st snapshots.list) <(echo "$NOW") | cut -c1-60 | head -2 | tr '\n' ';'))"
[ "$(grep -c "upperdir=$(st upperdir)" /proc/self/mounts || true)" = "$(st mounts.count)" ] || fail "the container's snapshot is still mounted somewhere else on the node (a mount was left behind)"
[ "$(sudo stat -c %i "$SRC")" = "$(st src.stat | awk '{print $1}')" ] || fail "the original report is another file now (it was replaced)"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
