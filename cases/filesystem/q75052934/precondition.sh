#!/bin/bash
set -e

CASE_ID="bench75052934"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
CTL_DIR="$LIB_BASE/bin"
CTD_SOCK="$RUN_BASE/containerd.sock"
TOOLS_DIR="$LIB_BASE/tools"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
VOL_DIR="$WORK_DIR/volume"
POD_NAME="$CASE_ID-pod"
APP_NAME="$CASE_ID-app"

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
lastlog() { "${CRI[@]}" logs --tail=1 "$APP_ID" 2>/dev/null | tail -1; }      # the newest line the application printed
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" <<<"$2"; }                         # field of such a line
wait_log() {   # $1 = field, $2 = expected value, $3 = seconds: wait until the application itself reports the value
    local i L
    for i in $(seq 1 "$(( $3 * 2 ))"); do
        L=$(lastlog)
        [ "$(field "$1" "$L")" = "$2" ] && return 0
        sleep 0.5
    done
    return 1
}
# the mountinfo line of mount point $2 in the mount namespace of host pid $1 ('' when there is none)
minfo() { sudo awk -v mp="$2" '$5 == mp {print; exit}' "/proc/$1/mountinfo" 2>/dev/null; }
# propagation fields (shared:N, master:N, ...) of such a line
mopts() { awk '{n = index($0, " - "); m = split(substr($0, 1, n), f, " "); s = ""; for (i = 7; i <= m; i++) s = s f[i] " "; print s}' <<<"$1"; }

echo "[precondition] checking the node's containerd (the process of setup) and its CRI..."
for f in containerd.id pod_id container_app pid starttime ns_mnt ns_pid ns_mnt_host ns_pid_host host_root_opts tok_tools tok_vol tok_diag containerdctl.sha; do
    sudo test -e "$STATE_DIR/$f" || fail "setup did not record $f"
done
alive_same containerd || fail "the recorded containerd is not running"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
echo "  -> OK"

echo "[precondition] checking container A: running, its recorded host pid and start time, its own pid and mount namespaces (not the host's)..."
APP_ID=$(st container_app); PID=$(st pid)
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "container A is not running"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || fail "container A has another host pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" | awk '{print $20}')" = "$(st starttime)" ] || fail "container A's process has another start time"
[ "$(sudo readlink "/proc/$PID/ns/mnt")" = "$(st ns_mnt)" ] || fail "A's mount namespace is not the recorded one"
[ "$(sudo readlink "/proc/$PID/ns/pid")" = "$(st ns_pid)" ] || fail "A's pid namespace is not the recorded one"
[ "$(st ns_mnt)" != "$(st ns_mnt_host)" ] || fail "A shares the host's mount namespace"
[ "$(st ns_pid)" != "$(st ns_pid_host)" ] || fail "A shares the host's pid namespace"
L=$(lastlog)
echo "     A says: $L"
[ "$(field pid "$L")" = "1" ] || fail "the application is not pid 1 in its pid namespace"
echo "  -> OK (host pid $PID, $(st ns_mnt), $(st ns_pid))"

echo "[precondition] checking A's volume: /vol is a bind of the host directory (same directory inode), A reads its token, private propagation..."
V=$(minfo "$PID" /vol)
[ -n "$V" ] || fail "A has no /vol mount"
[ "$(sudo stat -c '%d:%i' "/proc/$PID/root/vol")" = "$(stat -c '%d:%i' "$VOL_DIR")" ] || fail "/vol in A is not the host's volume directory"
[ "$(field vol "$L")" = "$(st tok_vol)" ] || fail "the application does not read the volume token"
R=$(minfo "$PID" /)
for line in "$R" "$V"; do
    if echo "$(mopts "$line")" | grep -qE 'shared:|master:'; then fail "A's mount propagation is not private: $(mopts "$line")"; fi
done
echo "  -> OK (/vol propagation: private)"

echo "[precondition] checking the tool directory exists only on the host: A has no /tools mount, its application reads nothing from it, a command"
echo "[precondition] run inside A cannot reach the tools..."
[ -s "$TOOLS_DIR/probe" ] && [ -x "$TOOLS_DIR/bin/diag" ] || fail "the tool directory is not filled"
TM=$(awk -v mp="$TOOLS_DIR" '$5 == mp {print; exit}' /proc/self/mountinfo)
echo "$(mopts "$TM")" | grep -q 'shared:' || fail "the tool directory is not a shared mount of the host (setup makes it one)"
[ -z "$(minfo "$PID" /tools)" ] || fail "A already has a /tools mount"
[ "$(field tools "$L")" = "missing" ] || fail "the application already reads /tools/probe"
if "${CRI[@]}" exec "$APP_ID" /tools/bin/diag >/dev/null 2>&1; then fail "the diagnostic tool already runs inside A"; fi
echo "  -> OK"

echo "[precondition] PASS - container A (own pid and mount namespaces, private propagation, its own volume) cannot see the host's tool directory."
