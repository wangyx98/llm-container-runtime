#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, no unit, no daemon),
# and every command here may fail without aborting the cleanup.

CASE_ID="bench68630961"
UNIT="$CASE_ID-containerd.service"
PREFIX="/opt/$CASE_ID"                # the "tarball install": bin/ and etc/
RUN_BASE="/run/$CASE_ID"              # socket and runtime state of the containerd
LIB_BASE="/var/lib/$CASE_ID"          # containerd root (content store, metadata)
WORK_DIR="/tmp/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"

# Kill the processes called $1 (exact process name) whose command line mentions this case's prefix or
# run dir. Matching by name first and by command line second is deliberate: 'pkill -f <path>' would
# also kill any shell whose own command line merely contains the path, including the one running this
# script. The system containerd of the host does not mention these paths and is left alone.
ours_re="/(opt|run|var/lib)/$CASE_ID"
kill_ours() {   # $1 = comm, $2 = signal
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$ours_re"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "$ours_re" && return 0
    done
    return 1
}

HAVE_SYSTEMD=0
command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && HAVE_SYSTEMD=1

# containers of this case first (a leftover one keeps a shim and mounts alive)
if [ -S "$CTD_SOCK" ] && command -v ctr >/dev/null 2>&1; then
    echo "[cleanup] removing every container and task of this case's containerd..."
    for ns in $(sudo timeout 20 ctr -a "$CTD_SOCK" namespaces ls -q 2>/dev/null); do
        for t in $(sudo timeout 20 ctr -a "$CTD_SOCK" -n "$ns" tasks ls -q 2>/dev/null); do
            sudo timeout 20 ctr -a "$CTD_SOCK" -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
            sudo timeout 20 ctr -a "$CTD_SOCK" -n "$ns" tasks delete "$t" >/dev/null 2>&1 || true
        done
        for c in $(sudo timeout 20 ctr -a "$CTD_SOCK" -n "$ns" containers ls -q 2>/dev/null); do
            sudo timeout 20 ctr -a "$CTD_SOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
        done
    done
fi

if [ "$HAVE_SYSTEMD" = 1 ]; then
    echo "[cleanup] stopping and removing the systemd unit $UNIT (every place a unit can live)..."
    # a transient unit (systemd-run) disappears by itself once stopped
    sudo timeout 60 systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    sudo timeout 60 systemctl stop "$UNIT" >/dev/null 2>&1 || true
    sudo timeout 20 systemctl kill --signal=SIGKILL "$UNIT" >/dev/null 2>&1 || true
    for d in /etc/systemd/system /etc/systemd/system.control /usr/local/lib/systemd/system \
             /usr/lib/systemd/system /lib/systemd/system /run/systemd/system /run/systemd/system.control \
             /run/systemd/transient; do
        [ -d "$d" ] && sudo find "$d" -maxdepth 3 -name "$UNIT*" -exec rm -rf {} + 2>/dev/null
    done
    sudo timeout 60 systemctl daemon-reload >/dev/null 2>&1 || true
    sudo timeout 20 systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
    # a unit with its own mount namespace (ProtectSystem=, ReadWritePaths=) leaves an empty directory in
    # systemd's propagate dir on some versions (seen on systemd 249); rmdir only removes an empty one
    sudo rmdir "/run/systemd/propagate/$UNIT" 2>/dev/null || true
fi

echo "[cleanup] stopping what is left of this case's containerd (also one a solution started by hand)..."
# a ctr client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours ctr KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
# the shims may outlive their daemon (KillMode=process keeps them on a stop)
for comm in containerd-shim containerd-shim-runc-v2; do
    kill_ours "$comm" KILL
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting
# anything: rm -rf must never walk into a live mount (overlay mounts of ctr, shm, netns).
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the containerd state, the tarball install and the work dir..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE" "$PREFIX"
# the shim keeps state in /run/containerd/runc/<namespace>, outside of RUN_BASE; those namespaces are
# shared with other containerds on the host, so nothing is removed from there
echo "[cleanup] (files a solution wrote to /tmp as root are not removable by the plain user: sticky /tmp)..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
