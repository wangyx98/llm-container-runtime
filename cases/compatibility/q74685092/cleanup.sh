#!/bin/bash
# Idempotent; no 'set -e'. The three daemons are PRIVATE and hold only this case's objects: their pods and containers are removed, the daemons and shims
# stopped, whatever else runs from the case's files killed, mounts below the case directories unmounted (deepest first), the directories removed.
# The pinned crictl in /var/cache/bench74685092 stays (sha256 is checked at every setup).
CASE_ID="bench74685092"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CRICTLBIN="$LIB_BASE/bin/crictl"

for n in k3s system worker; do
    sock="$RUN_BASE/$n/containerd.sock"
    if [ -S "$sock" ] && [ -x "$CRICTLBIN" ]; then
        C="sudo timeout -k 3 40 $CRICTLBIN --runtime-endpoint unix://$sock --image-endpoint unix://$sock --timeout 20s"
        echo "[cleanup] $n: removing every container and pod sandbox..."
        for c in $($C ps -a -q 2>/dev/null); do $C stop "$c" >/dev/null 2>&1; $C rm -f "$c" >/dev/null 2>&1; done
        for p in $($C pods -q 2>/dev/null); do $C stopp "$p" >/dev/null 2>&1; $C rmp -f "$p" >/dev/null 2>&1; done
    fi
    if [ -s "$RUN_BASE/$n/containerd.pid" ]; then
        pid=$(cat "$RUN_BASE/$n/containerd.pid" 2>/dev/null)
        echo "[cleanup] $n: stopping containerd (pid $pid)..."
        sudo kill "$pid" 2>/dev/null
        for _ in $(seq 1 20); do sudo kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
        sudo kill -9 "$pid" 2>/dev/null
    fi
done

echo "[cleanup] stopping any daemon, shim or workload still running from the case's files..."
protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done
for _ in 1 2 3; do
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        exe="$(sudo readlink "$d/exe" 2>/dev/null)"
        case "$exe" in "$LIB_BASE"/*|"$RUN_BASE"/*|"$WORK_DIR"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        cmd="$(sudo tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$cmd" in
            *containerd*"$RUN_BASE/"*|*containerd-shim*"$RUN_BASE/"*|*containerd-shim*"$LIB_BASE/"*) sudo kill -KILL "$pid" 2>/dev/null ;;
        esac
    done
    sudo pkill -9 -x bench-app 2>/dev/null
    sudo pkill -9 -x bench-pause 2>/dev/null
    sleep 0.3
done

echo "[cleanup] unmounting whatever is mounted below the case directories (deepest first)..."
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] the host's /run/containerd: removing the runc state and shim sockets this case's shims left there (what setup did not find), nothing else..."
if [ -f "$LIB_BASE/hostrun.base" ] && [ -d /run/containerd ]; then
    if [ "$(sudo cat "$LIB_BASE/hostrun.base")" = "NOEXIST" ]; then
        sudo rm -rf /run/containerd
    else
        for f in $(sudo find /run/containerd/runc /run/containerd/s -mindepth 1 -maxdepth 2 2>/dev/null | sort -r); do
            sudo grep -qxF "$f" "$LIB_BASE/hostrun.base" || sudo rm -rf "$f"
        done
    fi
fi

echo "[cleanup] removing the directories..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"
echo "[cleanup] done."
exit 0
