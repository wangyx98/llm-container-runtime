#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, daemons not running).
# The node is a private containerd; BuildKit (started by the solution) has to be stopped too. The pinned downloads in /var/cache/bench59759658 stay.
CASE_ID="bench59759658"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
SOCK="$RUN_BASE/containerd.sock"

protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done
kill_tree() {   # $1 = pid
    local c
    for c in $(ps -o pid= --ppid "$1" 2>/dev/null); do kill_tree "$c"; done
    sudo kill -KILL "$1" 2>/dev/null
}

echo "[cleanup] stopping BuildKit daemons that did not exist at setup (or that name the case's directories)..."
for pid in $(pgrep -x buildkitd 2>/dev/null); do
    case "$protect" in *" $pid "*) continue ;; esac
    if [ -f "$LIB_BASE/buildkitd.base" ]; then
        sudo grep -qx "$pid" "$LIB_BASE/buildkitd.base" 2>/dev/null && continue
        kill_tree "$pid"
    elif sudo cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' | grep -qF "$CASE_ID"; then
        kill_tree "$pid"
    fi
done

if [ -S "$SOCK" ] && command -v ctr >/dev/null 2>&1; then
    echo "[cleanup] removing every container of the node (all namespaces)..."
    for ns in $(sudo ctr -a "$SOCK" namespaces ls -q 2>/dev/null); do
        for c in $(sudo ctr -a "$SOCK" -n "$ns" containers ls -q 2>/dev/null); do
            sudo ctr -a "$SOCK" -n "$ns" tasks kill -s KILL "$c" >/dev/null 2>&1
            sleep 0.2
            sudo ctr -a "$SOCK" -n "$ns" tasks delete -f "$c" >/dev/null 2>&1
            sudo ctr -a "$SOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1
        done
    done
fi
if [ -s "$RUN_BASE/containerd.pid" ]; then
    pid=$(cat "$RUN_BASE/containerd.pid")
    echo "[cleanup] stopping the node's containerd (pid $pid)..."
    sudo kill "$pid" 2>/dev/null
    for _ in $(seq 1 20); do sudo kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    sudo kill -9 "$pid" 2>/dev/null
fi

echo "[cleanup] shims, container processes and anything that runs from the case's directories..."
for _ in 1 2 3; do
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        cmd="$(sudo tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$cmd" in
            *"$RUN_BASE"*|*"$LIB_BASE/"*|*"$WORK_DIR/"*) kill_tree "$pid"; continue ;;
        esac
        # a container process of the node: its root file system is an overlay below the node's data
        if sudo grep -qF "$LIB_BASE/data" "$d/mountinfo" 2>/dev/null; then kill_tree "$pid"; fi
    done
    sleep 0.3
done

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

echo "[cleanup] unmounting what is mounted below the case's directories, then removing them (and BuildKit's default directories, only if setup did not find them)..."
for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
    for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do sudo umount -l "$m" 2>/dev/null; done
done
for d in $(sudo cat "$LIB_BASE/created_dirs" 2>/dev/null); do sudo rm -rf --one-file-system "$d"; done
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"
echo "[cleanup] done."
exit 0
