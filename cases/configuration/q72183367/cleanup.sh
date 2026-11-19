#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench72183367"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CRIO_SOCK="$RUN_BASE/crio.sock"
REG_HOST="127.0.0.1:15183"
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
any_ours() {    # $1 = comm, $2 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${2:-$RUN_BASE}" && return 0
    done
    return 1
}

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] stopping k3s (the one this case started)..."
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -TERM "$p" 2>/dev/null || true; done
    for _ in $(seq 1 40); do pgrep -x k3s-server >/dev/null 2>&1 || break; sleep 1; done
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -KILL "$p" 2>/dev/null || true; done
fi

# the pods and containers of the private CRI-O: their ids are collected first (to remove their cgroups
# afterwards), the pods are stopped and removed through the CRI so that the runtime lets go of their mounts
IDS=""
if [ -S "$CRIO_SOCK" ] && command -v crictl >/dev/null 2>&1; then
    echo "[cleanup] removing every pod and container of the private CRI-O..."
    CR="sudo timeout -k 3 20 crictl --runtime-endpoint unix://$CRIO_SOCK --image-endpoint unix://$CRIO_SOCK"
    IDS="$($CR ps -a -q 2>/dev/null) $($CR pods -q 2>/dev/null)"
    for p in $($CR pods -q 2>/dev/null); do $CR stopp "$p" >/dev/null 2>&1 || true; done
    for p in $($CR pods -q 2>/dev/null); do $CR rmp -f "$p" >/dev/null 2>&1 || true; done
fi

echo "[cleanup] stopping this case's registry, CRI-O and what they left behind..."
# a client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours crictl KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours python3 KILL "$LIB_BASE/registry"      # the registry
kill_ours conmon KILL
kill_ours crio TERM "$LIB_BASE/crio/crio.conf"
for _ in $(seq 1 30); do any_ours crio "$LIB_BASE/crio/crio.conf" || break; sleep 0.5; done
kill_ours crio KILL "$LIB_BASE/crio/crio.conf"
# the programs of the containers (they run from the overlay mounts below the case's storage)
for d in /proc/[0-9]*; do
    case "$(sudo readlink "$d/exe" 2>/dev/null)" in
        "$LIB_BASE"/*) sudo kill -KILL "${d#/proc/}" 2>/dev/null || true ;;
    esac
done
sleep 0.5

# Unmount whatever is still mounted below the case directories and below the k3s directories (deepest
# first) BEFORE deleting anything: rm -rf must never walk into a live mount (the kubelet's own bind mounts,
# overlay mounts of a container, shm).
for _ in 1 2 3; do
    bases="$RUN_BASE $LIB_BASE $WORK_DIR"
    [ -e "$OWNED_MARKER" ] && bases="$bases /var/lib/kubelet /var/lib/rancher /run/k3s /var/log/pods"
    for base in $bases; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups CRI-O made for the pods and containers (they are named by the ids); empty now that the processes are gone
for id in $IDS; do
    [ ${#id} -ge 16 ] || continue
    sudo find /sys/fs/cgroup -maxdepth 8 -depth -type d -name "*$id*" -exec rmdir {} \; 2>/dev/null || true
done

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] removing the files k3s keeps outside the case's directories..."
    for d in $HOST_DIRS; do sudo rm -rf --one-file-system "$d"; done
    # the pods and containers logs of the kubelet: setup refused to start unless they were empty
    sudo rm -rf --one-file-system /var/log/pods /var/log/containers
fi

# credentials of the case's registry that a solution stored in the places where containers/image looks for them
# (the files are removed only when they mention the case's registry: they may be the machine's own)
for f in /run/containers/0/auth.json /root/.config/containers/auth.json /root/.docker/config.json /var/lib/kubelet/config.json; do
    if sudo grep -qF "$REG_HOST" "$f" 2>/dev/null; then sudo rm -f "$f"; fi
done

echo "[cleanup] removing the CRI-O, registry and k3s state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
