#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, daemons not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench67171982"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"

# The private containerd holds nothing but this case's objects, so everything in it goes.
# Containers and tasks first (a leftover task keeps a shim and mounts alive).
if [ -S "$SOCK" ] && command -v ctr >/dev/null 2>&1; then
    echo "[cleanup] removing every container and task of the private containerd..."
    for ns in $(sudo ctr -a "$SOCK" namespaces ls -q 2>/dev/null); do
        for t in $(sudo ctr -a "$SOCK" -n "$ns" tasks ls -q 2>/dev/null); do
            sudo ctr -a "$SOCK" -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
            sudo ctr -a "$SOCK" -n "$ns" tasks delete "$t" >/dev/null 2>&1 || true
        done
        for c in $(sudo ctr -a "$SOCK" -n "$ns" containers ls -q 2>/dev/null); do
            sudo ctr -a "$SOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
        done
    done
fi

if [ -s "$RUN_BASE/containerd.pid" ]; then
    pid=$(cat "$RUN_BASE/containerd.pid")
    echo "[cleanup] stopping containerd (pid $pid)..."
    sudo kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
        sudo kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    sudo kill -9 "$pid" 2>/dev/null || true
fi
# Whatever is still around that belongs to this case: shims and the workloads keep running when
# their containerd goes away. Only processes whose own command line names this case's directory
# are touched (a plain `pkill -f` on the path would also kill an unrelated shell that merely
# mentions it).
echo "[cleanup] stopping any daemon, shim or workload process left behind..."
for comm in containerd containerd-shim containerd-shim-runc-v2; do
    for pid in $(pgrep -x "$comm" 2>/dev/null); do
        if sudo cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | grep -qF "/run/$CASE_ID/"; then
            sudo kill -9 "$pid" 2>/dev/null || true
        fi
    done
done
# the workloads themselves are plain "/counter" processes; they are recognised by their root
# directory, which is one of this case's root file systems
for pid in $(pgrep -x counter 2>/dev/null); do
    case "$(sudo readlink "/proc/$pid/root" 2>/dev/null)" in
        "$LIB_BASE"/rootfs/*) sudo kill -9 "$pid" 2>/dev/null || true ;;
    esac
done
sleep 0.3

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting
# anything: rm -rf must never walk into a live mount.
for base in "$RUN_BASE" "$LIB_BASE"; do
    for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -F "$base/" | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
done

# the runc shim keeps its own state under /run/containerd/runc/<namespace>, outside of RUN_BASE;
# the namespace of this case is unique, and rmdir only removes it if nothing is left in it
sudo rmdir "/run/containerd/runc/$CASE_ID" 2>/dev/null || true
echo "[cleanup] removing the containerd state..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
