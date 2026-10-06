#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, daemons not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench74677606"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
DOCKER_SOCK="$RUN_BASE/docker.sock"
CTD_SOCKS=("$RUN_BASE/docker/containerd/containerd.sock" "$RUN_BASE/containerd/containerd.sock")

# Kill the processes called $1 (exact process name) whose command line mentions this case's run dir.
# Matching by name first and by command line second is deliberate: 'pkill -f <path>' would also kill
# any shell whose own command line merely contains the path, including the one running this script.
# A system Docker/containerd on the host does not mention the run dir and is left alone.
kill_ours() {   # $1 = comm, $2 = signal
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$RUN_BASE"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$RUN_BASE" && return 0
    done
    return 1
}

# containers of this case first (a leftover one keeps a shim and mounts alive); the Docker ones live in
# the namespace moby of Docker's containerd, the decoy of the other containerd in default
if [ -S "$DOCKER_SOCK" ] && command -v docker >/dev/null 2>&1; then
    echo "[cleanup] removing the containers of the private dockerd..."
    for c in $(sudo timeout 20 docker -H "unix://$DOCKER_SOCK" ps -aq 2>/dev/null); do
        sudo timeout 20 docker -H "unix://$DOCKER_SOCK" rm -f "$c" >/dev/null 2>&1 || true
    done
fi
for CTD_SOCK in "${CTD_SOCKS[@]}"; do
    if [ -S "$CTD_SOCK" ] && command -v ctr >/dev/null 2>&1; then
        echo "[cleanup] removing every container and task of the containerd on $CTD_SOCK..."
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
done

echo "[cleanup] stopping this case's dockerd and containerd and what they left behind..."
kill_ours dockerd TERM
for _ in $(seq 1 30); do any_ours dockerd || break; sleep 0.5; done
kill_ours dockerd KILL
kill_ours containerd TERM
for _ in $(seq 1 30); do any_ours containerd || break; sleep 0.5; done
kill_ours containerd KILL
# the shims may outlive their daemon
for comm in containerd-shim containerd-shim-runc-v2; do
    kill_ours "$comm" KILL
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting
# anything: rm -rf must never walk into a live mount (overlay mounts of ctr or Docker, shm, netns).
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the runc shim keeps its state under /run/containerd/runc/<namespace>, outside of RUN_BASE; the
# namespaces here (default, moby) are shared with other containerds on the host, so nothing is removed
# from there (the entries of this case's containers go away with their tasks)
echo "[cleanup] removing the containerd/docker state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp"
echo "[cleanup] (a file written by a root command is not removable by the plain user: sticky /tmp)..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
