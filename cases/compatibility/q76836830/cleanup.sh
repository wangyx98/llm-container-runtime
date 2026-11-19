#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running)
CASE_ID="bench76836830"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"

# Kill the processes called $1 (exact process name) whose command line mentions one of this case's directories. By name first and by command line second:
# 'pkill -f <path>' would also kill any shell whose own command line merely contains the path, including the one running this script. The host's own containerd
# and nginx do not mention the case's directories and are left alone.
ours() { sudo tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -qE "$RUN_BASE|$LIB_BASE|$WORK_DIR"; }
kill_ours() {   # $1 = comm, $2 = signal
    for pid in $(pgrep -x "$1" 2>/dev/null); do ours "$pid" && sudo kill "-$2" "$pid" 2>/dev/null; done
    return 0
}
any_ours() { for pid in $(pgrep -x "$1" 2>/dev/null); do ours "$pid" && return 0; done; return 1; }

echo "[cleanup] stopping nginx (the master process of this case; the workers follow), then a pull or a ctr/crictl client that was left running..."
kill_ours nginx TERM
for _ in $(seq 1 20); do any_ours nginx || break; sleep 0.25; done
kill_ours nginx KILL
# whatever still listens on the case's three ports (workers of a master that was killed hard; a front a solution started in place of nginx)
for port in 18076 15076 18176; do
    for pid in $(sudo ss -ltnpH "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do sudo kill -KILL "$pid" 2>/dev/null; done
done
kill_ours crictl KILL
kill_ours ctr KILL
kill_ours timeout KILL
kill_ours sudo KILL

echo "[cleanup] stopping the stand-ins of Nexus and the private containerd..."
kill_ours python3 KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
for comm in containerd-shim containerd-shim-runc-v2; do kill_ours "$comm" KILL; done
sleep 0.5

echo "[cleanup] unmounting whatever is still mounted below the case directories (deepest first) and removing them..."
for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^($RUN_BASE|$LIB_BASE|$WORK_DIR)(/|$)" | sort -r); do sudo umount -l "$m" 2>/dev/null; done
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"
echo "[cleanup] done."
exit 0
