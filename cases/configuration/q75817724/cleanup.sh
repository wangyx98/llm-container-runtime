#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench75817724"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
# k3s keeps files in fixed places outside the case's directories. They are removed only when setup.sh
# left this marker, i.e. when they are the case's own (setup.sh refuses to start on a host that has them).
OWNED_MARKER="$LIB_BASE/k3s_host_dirs_owned"
HOST_DIRS="/etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's
# run dir). Matching by name first and by command line second is deliberate: 'pkill -f <path>' would also
# kill any shell whose own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${3:-$RUN_BASE}"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] stopping k3s (the one this case started; its own containerd goes with it)..."
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -TERM "$p" 2>/dev/null || true; done
    for _ in $(seq 1 40); do pgrep -x k3s-server >/dev/null 2>&1 || break; sleep 1; done
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -KILL "$p" 2>/dev/null || true; done
    # whatever k3s' own containerd left behind: the daemon and the shims name its socket
    for comm in containerd containerd-shim containerd-shim-runc-v2; do
        kill_ours "$comm" KILL "/run/k3s/"
    done
    # the containers of the workloads outlive a killed shim: their cgroups are below the kubelet's
    for p in $(pgrep -x kubelet 2>/dev/null); do sudo kill -KILL "$p" 2>/dev/null || true; done
fi

echo "[cleanup] stopping this case's fixtures and what they left behind..."
# a client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours python3 KILL          # the registry and the egress proxy (their command lines name the run dir)
sleep 0.5

# Unmount whatever is still mounted below the case directories and below the k3s directories (deepest
# first) BEFORE deleting anything: rm -rf must never walk into a live mount (kubelet's own bind mount,
# overlay mounts of a container, shm).
for _ in 1 2 3; do
    bases="$RUN_BASE $LIB_BASE $WORK_DIR"
    [ -e "$OWNED_MARKER" ] && bases="$bases /var/lib/kubelet /var/lib/rancher /run/k3s"
    for base in $bases; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# A solution that put the CA into the trust store of the host leaves a file in /usr/local/share/ca-certificates.
# setup.sh recorded what the directory held: whatever is not on that list is removed and the bundle rebuilt.
if [ -f "$WORK_DIR/.bench/hosttrust.0" ]; then
    changed=""
    for f in /usr/local/share/ca-certificates/*; do
        [ -e "$f" ] || continue
        grep -qxF "$(basename "$f")" "$WORK_DIR/.bench/hosttrust.0" || { sudo rm -f "$f"; changed=1; }
    done
    if [ -n "$changed" ] && command -v update-ca-certificates >/dev/null 2>&1; then
        echo "[cleanup] removing the CA a solution added to the trust store of the host..."
        sudo update-ca-certificates --fresh >/dev/null 2>&1 || true
    fi
fi

# The directory of the docker-style layout (/etc/containerd/certs.d) that a solution may write. setup.sh recorded what it held
# before: whatever is not on that list was added by a solution and is removed; the directories are removed only when they
# did not exist before.
CERTS_DIR="/etc/containerd/certs.d"
if [ -f "$LIB_BASE/certs.orig" ] && [ -d "$CERTS_DIR" ]; then
    echo "[cleanup] removing the entries a solution added to $CERTS_DIR..."
    for f in "$CERTS_DIR"/*; do
        [ -e "$f" ] || continue
        grep -qxF "$(basename "$f")" "$LIB_BASE/certs.orig" || sudo rm -rf --one-file-system "$f"
    done
elif [ -e "$LIB_BASE/certs.absent" ]; then
    echo "[cleanup] removing $CERTS_DIR (it did not exist before this case)..."
    sudo rm -rf --one-file-system "$CERTS_DIR"
fi
if [ -e "$LIB_BASE/certs.absent" ]; then
    sudo rmdir "$CERTS_DIR" 2>/dev/null || true
fi
if [ -e "$LIB_BASE/etc_containerd.absent" ]; then
    sudo rmdir /etc/containerd 2>/dev/null || true
fi

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] removing the files k3s keeps outside the case's directories..."
    for d in $HOST_DIRS; do sudo rm -rf --one-file-system "$d"; done
    # the kubelet also creates these two (and never removes them); rmdir removes them only when empty
    sudo rmdir /var/log/pods /var/log/containers 2>/dev/null || true
fi

echo "[cleanup] removing the case state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
