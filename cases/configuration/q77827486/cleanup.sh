#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench77827486"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
# k3s keeps files in fixed places outside the case's directories, and a solution may put the registry credentials into CRI-O's default places
# (/run/containers/0/auth.json, /root/.docker/config.json). They are removed only when setup.sh left this marker, i.e. when they are the
# case's own (setup.sh refuses to start on a host that has them).
OWNED_MARKER="$LIB/host_dirs_owned"
HOST_DIRS="/etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s"

# Kill the processes called $1 (exact process name) whose command line mentions $3 (default: this case's
# run dir). Matching by name first and by command line second is deliberate: 'pkill -f <path>' would also
# kill any shell whose own command line merely contains the path, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${3:-$RUN}"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}
any_ours() {    # $1 = comm, $2 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "${2:-$RUN}" && return 0
    done
    return 1
}

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] stopping k3s (the one this case started)..."
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -TERM "$p" 2>/dev/null || true; done
    for _ in $(seq 1 40); do pgrep -x k3s-server >/dev/null 2>&1 || break; sleep 1; done
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -KILL "$p" 2>/dev/null || true; done
fi

# the pods and containers of CRI-O first: they run forever, and a leftover one keeps a conmon and mounts alive
if [ -S "$RUN/crio.sock" ] && [ -x "$LIB/bin/crictl" ]; then
    echo "[cleanup] removing every pod and container of the CRI-O of the case..."
    sudo timeout -k 3 90 "$LIB/bin/crictl" -r "unix://$RUN/crio.sock" -i "unix://$RUN/crio.sock" --timeout 60s rmp -f -a >/dev/null 2>&1 || true
fi

echo "[cleanup] stopping CRI-O and the registry of the case and what they left behind..."
kill_ours crictl KILL
kill_ours timeout KILL
kill_ours sudo KILL
kill_ours crio TERM
for _ in $(seq 1 30); do any_ours crio || break; sleep 0.5; done
kill_ours crio KILL
# the registry's command line names the case's directory in /var/lib, not in /run
kill_ours registry TERM "$LIB"
for _ in $(seq 1 20); do any_ours registry "$LIB" || break; sleep 0.5; done
kill_ours registry KILL "$LIB"
kill_ours conmon KILL
sleep 0.5

# Unmount whatever is still mounted below the case directories and below the fixed directories (deepest first) BEFORE deleting
# anything: rm -rf must never walk into a live mount (kubelet's own bind mount, overlay mounts of a container, shm).
for _ in 1 2 3; do
    bases="$RUN $LIB $WORK_DIR"
    [ -e "$OWNED_MARKER" ] && bases="$bases /var/lib/kubelet /var/lib/rancher /run/k3s"
    for base in $bases; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the two names of the registry
sudo sed -i '/# bench77827486$/d' /etc/hosts 2>/dev/null

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] removing the files k3s and the solutions keep outside the case's directories..."
    for d in $HOST_DIRS; do sudo rm -rf --one-file-system "$d"; done
    sudo rm -f /run/containers/0/auth.json /root/.docker/config.json
    sudo rmdir /run/containers/0 /run/containers /root/.docker 2>/dev/null || true
    # the logs of the case's Pods and containers: only the entries that setup did not find there (the lists are recorded before k3s starts)
    for d in pods containers; do
        [ -e "$LIB/logs.$d.before" ] || continue
        for f in $(sudo ls -A "/var/log/$d" 2>/dev/null); do
            grep -qxF "$f" "$LIB/logs.$d.before" || sudo rm -rf --one-file-system "/var/log/$d/$f"
        done
        # nothing was there before: the kubelet created the directory itself
        [ -s "$LIB/logs.$d.before" ] || sudo rmdir "/var/log/$d" 2>/dev/null || true
    done
fi

# the cgroups of the containers of the case's CRI-O (below "crio"; setup recorded the ones that were there before): empty ones only, deepest first
if [ -e "$LIB/cgroups.before" ]; then
    for d in $(sudo find /sys/fs/cgroup -depth -type d \( -name crio -o -path '*/crio/*' \) 2>/dev/null); do
        grep -qxF "$d" "$LIB/cgroups.before" || sudo rmdir "$d" 2>/dev/null || true
    done
fi

# the bridge the CNI plugin makes when a Pod without host network is created (the checks use host network; a solution may not)
if [ -e /sys/class/net/bench0 ] && [ -e "$OWNED_MARKER" ]; then
    sudo python3 - bench0 <<'PYEOF' 2>/dev/null || true
import fcntl
import socket
import struct
import sys

name = sys.argv[1].encode()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
flags = struct.unpack("16sh", fcntl.ioctl(s, 0x8913, struct.pack("16sh", name, 0)))[1]     # SIOCGIFFLAGS
fcntl.ioctl(s, 0x8914, struct.pack("16sh", name, flags & ~1))                              # SIOCSIFFLAGS: down
fcntl.ioctl(s, 0x89a1, name.ljust(16, b"\0"))                                              # SIOCBRDELBR
PYEOF
fi

echo "[cleanup] removing the registry, CRI-O and k3s state..."
sudo rm -rf --one-file-system "$RUN" "$LIB"

echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state (the downloads in /var/cache/$CASE_ID are kept)."
