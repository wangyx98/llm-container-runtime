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
rndv() { python3 -c 'import secrets; print(secrets.token_hex(8))'; }

echo "[oracle] check 0: the node's containerd is still the one of setup, its start script is unchanged, and its CRI answers..."
alive_same containerd || fail "containerd is not the process of setup (it was restarted or replaced)"
[ "$(sudo sha256sum "$CTL_DIR/containerdctl" | awk '{print $1}')" = "$(st containerdctl.sha)" ] || fail "$CTL_DIR/containerdctl was changed"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of containerd does not answer"
for f in container_app pid starttime ns_mnt ns_pid host_root_opts tok_tools tok_vol tok_diag; do
    [ -n "$(st $f)" ] || [ "$f" = host_root_opts ] || fail "setup's recorded $f is missing"
done
APP_ID=$(st container_app); PID=$(st pid)
echo "  -> OK"

echo "[oracle] check 1: container A is the same one: same container, same host process (pid and start time), same mount and pid"
echo "[oracle]          namespaces (inodes), still pid 1 in its own pid namespace with only its own processes in view..."
[ "$("${CRI[@]}" inspect -o go-template --template '{{.status.state}}' "$APP_ID" 2>/dev/null)" = "CONTAINER_RUNNING" ] || fail "container A is not running (stopped, removed or recreated)"
[ "$("${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$APP_ID" 2>/dev/null)" = "$PID" ] || fail "container A runs under another host pid"
[ "$(sudo sed -E 's/^[0-9]+ \(.*\) //' "/proc/$PID/stat" 2>/dev/null | awk '{print $20}')" = "$(st starttime)" ] || fail "container A's process was restarted (its start time changed)"
[ "$(sudo readlink "/proc/$PID/ns/mnt")" = "$(st ns_mnt)" ] || fail "A's mount namespace is not the original one"
[ "$(sudo readlink "/proc/$PID/ns/pid")" = "$(st ns_pid)" ] || fail "A's pid namespace is not the original one"
L=$(lastlog)
[ "$(field pid "$L")" = "1" ] && [ "$(field nproc "$L")" = "1" ] || fail "the application's pid view is not the one of its own pid namespace ($L)"
echo "  -> OK (host pid $PID, $(st ns_mnt), $(st ns_pid))"

echo "[oracle] check 2: A's ORIGINAL application process (it is the one that prints these lines) reads the tool directory's probe file"
echo "[oracle]          through /tools: the file of the host directory, with the setup's token..."
wait_log tools "$(st tok_tools)" 20 || { echo "     last line: $(lastlog)"; fail "the application does not see the tool directory at /tools/probe"; }
echo "  -> OK ($(lastlog | cut -c1-120))"

echo "[oracle] check 3: it is the host directory itself, live: a file the oracle writes into the host directory now shows up for A's"
echo "[oracle]          application within seconds, and again after the next change (a copy would not follow)..."
for round in 1 2; do
    V=$(rndv)
    printf 'live-%s\n' "$V" | sudo tee "$TOOLS_DIR/live" >/dev/null
    wait_log live "live-$V" 15 || { echo "     last line: $(lastlog)"; fail "a file written into the host directory (round $round) does not reach A: /tools is not a live view of it"; }
done
echo "  -> OK (A reads $(field live "$(lastlog)"))"

echo "[oracle] check 4: in A's mount table /tools is a real bind mount of that directory: the same directory (device and inode) as"
echo "[oracle]          the host's, from the same filesystem, not a copy on another filesystem..."
T=$(minfo "$PID" /tools)
[ -n "$T" ] || fail "A's mount table has no mount at /tools"
echo "     $(echo "$T" | cut -c1-150)"
[ "$(sudo stat -c '%d:%i' "/proc/$PID/root/tools")" = "$(stat -c '%d:%i' "$TOOLS_DIR")" ] || fail "/tools in A is not the host's tool directory (another device or inode: a copy)"
HOSTMM=$(python3 -c 'import os,sys; d=os.stat(sys.argv[1]).st_dev; print("%d:%d" % (os.major(d), os.minor(d)))' "$TOOLS_DIR")
[ "$(echo "$T" | awk '{print $3}')" = "$HOSTMM" ] || fail "the mount at /tools is from another device than the host's tool directory"
echo "  -> OK (device $HOSTMM)"

echo "[oracle] check 5: the tools work inside A: a new process in A's namespaces runs the tool from /tools/bin..."
OUT=$("${CRI[@]}" exec "$APP_ID" /tools/bin/diag 2>&1 || true)
[ "$OUT" = "bench75052934-diag-ok token=$(st tok_diag)" ] || fail "'crictl exec <A> /tools/bin/diag' printed: $OUT"
echo "  -> OK ($OUT)"

echo "[oracle] check 6: A's own volume is intact: /vol is still the host's volume directory, and a change of its file reaches the"
echo "[oracle]          application..."
V=$(minfo "$PID" /vol)
[ -n "$V" ] || fail "A lost its /vol mount"
[ "$(sudo stat -c '%d:%i' "/proc/$PID/root/vol")" = "$(stat -c '%d:%i' "$VOL_DIR")" ] || fail "/vol in A is not the host's volume directory any more"
NV="vol-$(rndv)"
printf '%s\n' "$NV" > "$VOL_DIR/vol-token"
wait_log vol "$NV" 15 || fail "the application does not read the changed volume file"
echo "  -> OK"

echo "[oracle] check 7: mount propagation was not loosened: the host's root mount has the propagation it had, and A's root, /vol and"
echo "[oracle]          /tools mounts are still private (no shared or slave peers)..."
HR=$(awk '$5 == "/" {print; exit}' /proc/self/mountinfo)
[ "$(mopts "$HR")" = "$(st host_root_opts)" ] || fail "the propagation of the host's root mount changed: '$(st host_root_opts)' -> '$(mopts "$HR")'"
for mp in / /vol /tools; do
    if echo "$(mopts "$(minfo "$PID" "$mp")")" | grep -qE 'shared:|master:'; then fail "A's mount $mp is no longer private: $(mopts "$(minfo "$PID" "$mp")")"; fi
done
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
