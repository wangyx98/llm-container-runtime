#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench73550556"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's run dir). Matching by name first and by command line second is
# deliberate: 'pkill -f <path>' would also kill any shell whose own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if { sudo tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qF "${3:-$RUN}"; } 2>/dev/null; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

# the clients of a checker that was interrupted, and the pod with its container first: the container runs for ever
kill_ours crictl KILL
kill_ours timeout KILL
if [ -S "$RUN/containerd.sock" ] && [ -x "$LIB/bin/crictl" ]; then
    echo "[cleanup] removing the pod and its container of the case..."
    sudo timeout -k 3 90 "$LIB/bin/crictl" --timeout 60s rmp -f -a >/dev/null 2>&1 || true
fi

echo "[cleanup] stopping the collector, the node's containerd and the shims it left..."
for t in otelctl nodectl; do
    if [ -x "$LIB/bin/$t" ]; then sudo timeout -k 3 60 "$LIB/bin/$t" stop >/dev/null 2>&1 || true; fi
done
for sig in TERM KILL; do
    kill_ours otelcol "$sig" "$CASE_ID"
    kill_ours containerd "$sig" "$CASE_ID"
    kill_ours containerd-shim-runc-v2 "$sig" "$CASE_ID"
    for _ in $(seq 1 20); do
        left=0
        for pid in $(pgrep -x containerd 2>/dev/null) $(pgrep -x containerd-shim-runc-v2 2>/dev/null) $(pgrep -x otelcol 2>/dev/null); do
            { sudo tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qF "$CASE_ID"; } 2>/dev/null && left=1
        done
        [ "$left" = 0 ] && break
        sleep 0.5
    done
done
# whatever else still runs from the case's directories or with the case's id on its command line (a client, a listener or a script of a solution), except this script and its callers
for pid in $(sudo find /proc -maxdepth 1 -regex '/proc/[0-9]+' 2>/dev/null | sed 's|/proc/||'); do
    [ "$pid" = "$$" ] && continue
    exe=$(sudo readlink "/proc/$pid/exe" 2>/dev/null)
    cmd=$({ sudo tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null)
    case "$exe" in *"$CASE_ID"*) sudo kill -KILL "$pid" 2>/dev/null || true; continue;; esac
    case "$(sudo cat "/proc/$pid/comm" 2>/dev/null)" in
        python3|python|nc|ncat|socat|logger)
            case "$cmd" in *cleanup.sh*|*setup.sh*|*oracle.sh*|*precondition.sh*) ;; *"$CASE_ID"*) sudo kill -KILL "$pid" 2>/dev/null || true ;; esac ;;
    esac
done
# the processes of the pod's cgroup: a container's init (here the pause or the app) outlives its shim when the shim is killed first (the node's containerd was stopped or broken by a solution)
for _ in 1 2 3; do
    for f in $(sudo find /sys/fs/cgroup -path "*/$CASE_ID/*" -name cgroup.procs 2>/dev/null); do
        for pid in $(sudo cat "$f" 2>/dev/null); do sudo kill -KILL "$pid" 2>/dev/null || true; done
    done
    sleep 0.3
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (the container's rootfs, shm, namespaces).
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups of the pod (/bench73550556 in every hierarchy): empty ones only, deepest first
for d in $(sudo find /sys/fs/cgroup -depth -type d -path "*/$CASE_ID" -o -depth -type d -path "*/$CASE_ID/*" 2>/dev/null); do
    sudo rmdir "$d" 2>/dev/null || true
done

echo "[cleanup] removing the node, the collector, the spans and the work dir (the downloaded files stay in /var/cache/$CASE_ID)..."
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
