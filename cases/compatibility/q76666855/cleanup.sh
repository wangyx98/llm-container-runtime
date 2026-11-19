#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running)
CASE_ID="bench76666855"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
LOAD_BIN="/jmeter/bin/run-lp-endpoint-tests"

# Kill the processes called $1 (exact process name) whose command line mentions one of this case's directories. By name first and by command line second: 'pkill -f <path>' would
# also kill any shell whose own command line merely contains the path, including the one running this script. The machine's own dockerd and containerd do not mention the case's
# directories and are left alone.
ours() { sudo tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -qE "$RUN_BASE|$LIB_BASE|$WORK_DIR"; }
kill_ours() {   # $1 = comm, $2 = signal
    for pid in $(pgrep -x "$1" 2>/dev/null); do ours "$pid" && sudo kill "-$2" "$pid" 2>/dev/null; done
    return 0
}
any_ours() { for pid in $(pgrep -x "$1" 2>/dev/null); do ours "$pid" && return 0; done; return 1; }

echo "[cleanup] stopping a job's client that was left running, then the lab's dockerd (it stops its containers) and containerd..."
for c in docker ctr timeout sudo; do kill_ours "$c" KILL; done
kill_ours dockerd TERM
for _ in $(seq 1 40); do any_ours dockerd || break; sleep 0.5; done
kill_ours dockerd KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
for comm in containerd-shim containerd-shim-runc-v2; do kill_ours "$comm" KILL; done
# a container's program outlives a shim that was killed: it is the case's own program (the path exists only in the case's image)
sudo pkill -KILL -f "^$LOAD_BIN " 2>/dev/null
kill_ours python3 KILL
sleep 0.5

echo "[cleanup] unmounting whatever is still mounted below the case directories (deepest first), removing the containers' cgroups and the directories..."
for _ in 1 2 3; do
    for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^($RUN_BASE|$LIB_BASE|$WORK_DIR)(/|$)" | sort -r); do sudo umount -l "$m" 2>/dev/null; done
    sudo findmnt -rn -o TARGET 2>/dev/null | grep -qE "^($RUN_BASE|$LIB_BASE|$WORK_DIR)(/|$)" || break
    sleep 0.5
done
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 6 -depth -type d -path "*/$CASE_ID/*" -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 6 -depth -type d -name "$CASE_ID" -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 6 -type d -name "$CASE_ID" 2>/dev/null | grep -q . || break
    sleep 0.5
done
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"
echo "[cleanup] done."
exit 0
