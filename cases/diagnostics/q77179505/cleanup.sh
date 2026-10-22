#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench77179505"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's run dir). Matching by name first and by command line second is
# deliberate: 'pkill -f <path>' would also kill any shell whose own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${3:-$RUN}"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

# the programs of a solution that are still running (a ctr, a python script whose command line names the case)
kill_ours ctr KILL
for p in $(pgrep -x python3 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && ! sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE "cleanup.sh|setup.sh|oracle.sh|precondition.sh" && sudo kill -KILL "$p" 2>/dev/null
done

echo "[cleanup] stopping the node's containerd..."
if [ -x "$LIB/bin/nodectl" ]; then sudo timeout -k 3 60 "$LIB/bin/nodectl" stop >/dev/null 2>&1 || true; fi
for sig in TERM KILL; do
    # the node's containerd is started with 'containerd --config <lib>/etc/containerd.toml'
    for pid in $(pgrep -x containerd 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && sudo kill "-$sig" "$pid" 2>/dev/null
        [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" != "${LIB}/node/bin/containerd" ] || sudo kill "-$sig" "$pid" 2>/dev/null
    done
    for _ in $(seq 1 20); do
        left=0
        for pid in $(pgrep -x containerd 2>/dev/null); do
            [ "$(sudo readlink "/proc/$pid/exe" 2>/dev/null)" = "${LIB}/node/bin/containerd" ] && left=1
        done
        [ "$left" = 0 ] && break
        sleep 0.5
    done
done

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (a solution may have mounted an overlay of a snapshot).
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
    # an overlay or bind mount of a snapshot made anywhere else: its options name the snapshotter's directory
    for m in $(sudo awk -v id="$CASE_ID" 'index($0, id) {print $2}' /proc/self/mountinfo 2>/dev/null | sort -r); do
        case "$m" in "$RUN"*|"$LIB"*|"$WORK_DIR"*) ;; *) sudo umount -l "$m" 2>/dev/null || true ;; esac
    done
done

echo "[cleanup] removing the node, its state and the work dir (the downloaded containerd stays in /var/cache/$CASE_ID)..."
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
