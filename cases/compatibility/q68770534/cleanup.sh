#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, daemon not running), and every command here may fail without
# aborting the cleanup.

CASE_ID="bench68770534"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"

# This case runs one PRIVATE containerd daemon (the node). It holds nothing but
# this case's objects, so everything it contains is removed.
if [ -S "$SOCK" ] && command -v crictl >/dev/null 2>&1; then
    CRICTL="sudo crictl --runtime-endpoint unix://$SOCK --image-endpoint unix://$SOCK --timeout 20s"
    echo "[cleanup] removing every container and pod sandbox of the node..."
    for c in $($CRICTL ps -a -q 2>/dev/null); do
        $CRICTL stop "$c" >/dev/null 2>&1 || true
        $CRICTL rm -f "$c" >/dev/null 2>&1 || true
    done
    for p in $($CRICTL pods -q 2>/dev/null); do
        $CRICTL stopp "$p" >/dev/null 2>&1 || true
        $CRICTL rmp -f "$p" >/dev/null 2>&1 || true
    done
fi

if [ -s "$RUN_BASE/containerd.pid" ]; then
    pid=$(cat "$RUN_BASE/containerd.pid")
    echo "[cleanup] stopping the node's containerd (pid $pid)..."
    sudo kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        sudo kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    sudo kill -9 "$pid" 2>/dev/null || true
fi

# Whatever is still around: shims keep running when their containerd goes
# away. Only containerd daemons and shims whose own command line names this
# case's directory are touched (a plain `pkill -f` on the path would also kill
# an unrelated shell that merely mentions it).
echo "[cleanup] stopping any daemon, shim or workload process left behind..."
for comm in containerd containerd-shim; do
    for pid in $(pgrep -x "$comm" 2>/dev/null); do
        if sudo cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | grep -qF "/run/$CASE_ID"; then
            sudo kill -9 "$pid" 2>/dev/null || true
        fi
    done
done
sudo pkill -9 -x bench-app 2>/dev/null || true
sudo pkill -9 -x bench-pause 2>/dev/null || true
sleep 0.3

# Unmount whatever is still mounted below the node directories (deepest
# first) BEFORE deleting anything: rm -rf must never walk into a live mount.
for base in "$RUN_BASE" "$LIB_BASE"; do
    for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -F "$base/" | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
done

# the host's /run/containerd: what the shims left there (the runc state and sockets of this case), nothing else
echo "[cleanup] the host's /run/containerd: removing what the node's shims left there (what setup did not find)..."
if [ -f "$LIB_BASE/hostrun.base" ] && [ -d /run/containerd ]; then
    if [ "$(sudo cat "$LIB_BASE/hostrun.base")" = "NOEXIST" ]; then
        sudo rm -rf /run/containerd
    else
        for f in $(sudo find /run/containerd/runc /run/containerd/s -mindepth 1 -maxdepth 2 2>/dev/null | sort -r); do
            sudo grep -qxF "$f" "$LIB_BASE/hostrun.base" || sudo rm -rf "$f"
        done
    fi
fi

# setup.sh pointed /etc/crictl.yaml at the node; put back what was there before
if [ -f "$LIB_BASE/crictl.yaml.orig" ]; then
    echo "[cleanup] restoring /etc/crictl.yaml..."
    sudo cp -p "$LIB_BASE/crictl.yaml.orig" /etc/crictl.yaml
elif [ -f "$LIB_BASE/crictl.yaml.absent" ]; then
    echo "[cleanup] removing the /etc/crictl.yaml that setup created..."
    sudo rm -f /etc/crictl.yaml
fi

echo "[cleanup] removing the node's runtime state and image store..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir (JSON configs, hidden state)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
