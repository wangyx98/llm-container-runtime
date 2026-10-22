#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench75622952"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
ADDR="10.75.62.29"
ALIAS="lo:b75622952"

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

# the clients of a checker that was interrupted, and the pod with its container first: the container runs for ever
kill_ours crictl KILL
kill_ours timeout KILL
if [ -S "$RUN/containerd.sock" ] && [ -x "$LIB/bin/crictl" ]; then
    echo "[cleanup] removing the pod and its container of the case..."
    sudo timeout -k 3 90 "$LIB/bin/crictl" --timeout 60s rmp -f -a >/dev/null 2>&1 || true
fi

echo "[cleanup] stopping the node's containerd and the shims it left, and the registry front..."
if [ -x "$LIB/bin/nodectl" ]; then sudo timeout -k 3 60 "$LIB/bin/nodectl" stop >/dev/null 2>&1 || true; fi
for sig in TERM KILL; do
    kill_ours containerd "$sig" "$CASE_ID"
    kill_ours containerd-shim-runc-v2 "$sig" "$CASE_ID"
    for p in $(pgrep -x python3 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF "$LIB/front/front.py" && sudo kill "-$sig" "$p" 2>/dev/null
    done
    for _ in $(seq 1 20); do
        left=0
        for pid in $(pgrep -x containerd 2>/dev/null) $(pgrep -x containerd-shim-runc-v2 2>/dev/null) $(pgrep -x python3 2>/dev/null); do
            sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID" && left=1
        done
        [ "$left" = 0 ] && break
        sleep 0.5
    done
done
# whatever else still runs from the case's directories (a program of a solution started on the host)
for pid in $(sudo find /proc -maxdepth 1 -regex '/proc/[0-9]+' 2>/dev/null | sed 's|/proc/||'); do
    [ "$pid" = "$$" ] && continue
    if sudo readlink "/proc/$pid/exe" 2>/dev/null | grep -qF "$CASE_ID"; then sudo kill -KILL "$pid" 2>/dev/null || true; fi
done
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (the containers' rootfs, shm, namespaces).
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups of the pod (/bench75622952 in every hierarchy): empty ones only, deepest first
for d in $(sudo find /sys/fs/cgroup -depth -type d -path "*/$CASE_ID" -o -depth -type d -path "*/$CASE_ID/*" 2>/dev/null); do
    sudo rmdir "$d" 2>/dev/null || true
done

# a sample may have put the lab's CA into the machine's trust store: take it out again (only a file with exactly the lab CA's content), and rebuild the bundle
if [ -f "$LIB/pki/ca.crt" ] && [ -d /usr/local/share/ca-certificates ]; then
    removed=0
    for f in /usr/local/share/ca-certificates/*; do
        [ -f "$f" ] && sudo cmp -s "$f" "$LIB/pki/ca.crt" && sudo rm -f "$f" && removed=1
    done
    [ "$removed" = 1 ] && sudo update-ca-certificates --fresh >/dev/null 2>&1
fi

echo "[cleanup] removing the registry's address $ADDR, the node, its state and the work dir (the downloaded files stay in /var/cache/$CASE_ID)..."
if [ -f "$WORK_DIR/.bench/alias.py" ]; then
    sudo python3 "$WORK_DIR/.bench/alias.py" del "$ALIAS" "$ADDR" 2>/dev/null || true
else
    sudo python3 - "$ALIAS" <<'PY' 2>/dev/null || true
import fcntl, socket, struct, sys
fcntl.ioctl(socket.socket(socket.AF_INET, socket.SOCK_DGRAM), 0x8914, struct.pack("16sH14x", sys.argv[1].encode(), 0))
PY
fi
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
