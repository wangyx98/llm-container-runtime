#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench63132692"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/containerd.sock"

# The processes of the lab: those whose command line names the lab's directories, or whose executable is a file of the lab (the workloads of runc pods run /bin/spin of an image below $LIB).
# gVisor's own processes (runsc-sandbox, runsc-gofer, the shims) name $RUN or $LIB on their command lines. This script and its parents are never touched.
sweep() {   # $1 = signal
    sudo bash -c '
        sig=$1; run=$2; lib=$3; me=$$; parent=$PPID
        for d in /proc/[0-9]*; do
            pid=${d#/proc/}
            [ "$pid" = "$me" ] || [ "$pid" = "$parent" ] || [ "$pid" = "$4" ] && continue
            cmd=$(tr "\0" " " < "$d/cmdline" 2>/dev/null)
            case "$cmd" in *cleanup.sh*|*setup.sh*|*oracle.sh*|*precondition.sh*) continue ;; esac
            exe=$(readlink "$d/exe" 2>/dev/null)
            case "$cmd $exe" in *"$run/"*|*"$lib/"*) kill "-$sig" "$pid" 2>/dev/null ;; esac
        done' _ "$1" "$RUN" "$LIB" "$PPID"
}
node_up() { [ -S "$SOCK" ] && [ -x "$LIB/bin/crictl" ]; }

echo "[cleanup] removing the pods of the lab's containerd..."
if node_up; then
    for p in $(sudo timeout -k 3 30 "$LIB/bin/crictl" pods -q 2>/dev/null); do
        sudo timeout -k 3 30 "$LIB/bin/crictl" stopp "$p" >/dev/null 2>&1
        sudo timeout -k 3 30 "$LIB/bin/crictl" rmp -f "$p" >/dev/null 2>&1
    done
fi

echo "[cleanup] stopping the lab's processes (gVisor's sandboxes and shims, the shims of runc, containerd)..."
sweep TERM
for _ in $(seq 1 20); do
    sudo pgrep -x containerd >/dev/null 2>&1 || break
    sudo bash -c 'for p in $(pgrep -x containerd); do tr "\0" " " < /proc/$p/cmdline | grep -qF "$1" && exit 1; done; exit 0' _ "$LIB/etc/containerd.toml" && break
    sleep 0.5
done
sweep KILL
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (runsc leaves a mount in its root).
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done
# the cgroup directories of the pods (the pods' cgroup parent contains the case id); where a controller is not mounted as a cgroup (net_cls, net_prio on some hosts) runsc makes plain
# directories with files in them, which rmdir cannot remove
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -path "*$CASE_ID*" -exec rmdir {} \; 2>/dev/null
    for d in /sys/fs/cgroup/*/"$CASE_ID" /sys/fs/cgroup/"$CASE_ID"; do [ -d "$d" ] && sudo rm -rf "$d" 2>/dev/null; done
    sudo find /sys/fs/cgroup -maxdepth 9 -type d -path "*$CASE_ID*" 2>/dev/null | grep -q . || break
    sleep 1
done

# The sockets of the shims are in /run/containerd/s, a fixed place of containerd's; a shim that ends badly (or after the removal of a gVisor sandbox) leaves its socket there. The dead sockets
# that are younger than the lab (the record of setup is older than they are) are the lab's.
if sudo test -f "$STATE_DIR/pins.txt"; then
    for sk in $(sudo find /run/containerd/s -maxdepth 1 -type s -newer "$STATE_DIR/pins.txt" 2>/dev/null); do
        sudo python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1])
except OSError:
    sys.exit(1)' "$sk" 2>/dev/null || sudo rm -f "$sk"
    done
fi

echo "[cleanup] removing the state of the lab and the work dir (the downloaded gVisor files stay in /var/cache/$CASE_ID)..."
sudo rm -rf --one-file-system "$RUN" "$LIB"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
