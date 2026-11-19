#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench76379942"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"
NEXUS_ADDR="10.66.79.42"

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

# the pods and containers of the private containerd: their ids are collected first (to remove their cgroups
# afterwards), the pods are stopped and removed through the CRI so that the runtime lets go of their mounts
IDS=""
if [ -S "$CTD_SOCK" ] && command -v crictl >/dev/null 2>&1; then
    echo "[cleanup] removing every pod and container of the private containerd..."
    CR="sudo timeout -k 3 20 crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"
    IDS="$($CR ps -a -q 2>/dev/null) $($CR pods -q 2>/dev/null)"
    for p in $($CR pods -q 2>/dev/null); do $CR stopp "$p" >/dev/null 2>&1 || true; done
    for p in $($CR pods -q 2>/dev/null); do $CR rmp -f "$p" >/dev/null 2>&1 || true; done
fi

echo "[cleanup] stopping this case's containerd and Nexus stand-in and what they left behind..."
# a client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its
# `timeout` and `sudo` parents alive; SIGKILL works on a stopped process
kill_ours crictl KILL
kill_ours ctr KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours python3 KILL "$LIB_BASE/nexus"          # the Nexus stand-in
kill_ours python3 KILL "$WORK_DIR"                # and any forwarder a solution started from the work dir
kill_ours containerd TERM "$LIB_BASE/etc/containerd.toml"
for _ in $(seq 1 30); do any_ours containerd "$LIB_BASE/etc/containerd.toml" || break; sleep 0.5; done
kill_ours containerd KILL "$LIB_BASE/etc/containerd.toml"
for comm in containerd-shim-runc-v2 containerd-shim; do kill_ours "$comm" KILL "$RUN_BASE"; done
# the programs of the containers (they run from the overlay mounts below the case's root)
for d in /proc/[0-9]*; do
    case "$(sudo readlink "$d/exe" 2>/dev/null)" in
        "$LIB_BASE"/*) sudo kill -KILL "${d#/proc/}" 2>/dev/null || true ;;
    esac
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything:
# rm -rf must never walk into a live mount (overlay mounts of a container, shm).
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR" $(ls -d "$WORK_DIR"-* 2>/dev/null); do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups containerd made for the pods and containers (they are named by the ids); empty now that the processes are gone
for id in $IDS; do
    [ ${#id} -ge 16 ] || continue
    sudo find /sys/fs/cgroup -maxdepth 8 -depth -type d -name "*$id*" -exec rmdir {} \; 2>/dev/null || true
done

# the address of Nexus, and the registry configuration a solution wrote for it in the usual place of the machine's own containerd (removed only
# when it names this case's address; the directories only when empty afterwards)
if ip -4 addr show dev lo 2>/dev/null | grep -qF "$NEXUS_ADDR/"; then sudo ip addr del "$NEXUS_ADDR/32" dev lo 2>/dev/null || true; fi
for f in /etc/containerd/certs.d/*/hosts.toml; do
    [ -e "$f" ] || continue
    if sudo grep -qF "$NEXUS_ADDR" "$f" 2>/dev/null; then sudo rm -f "$f"; sudo rmdir "$(dirname "$f")" 2>/dev/null || true; fi
done
sudo rmdir /etc/containerd/certs.d /etc/containerd 2>/dev/null || true
sudo iptables -t nat -S 2>/dev/null | grep -F "$NEXUS_ADDR" | sed 's/^-A /-D /' | while read -r rule; do sudo iptables -t nat $rule 2>/dev/null || true; done

echo "[cleanup] removing the containerd and Nexus state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
