#!/bin/bash
# Idempotent; no 'set -e'. The node is a mount namespace that only this case's processes live in: dockerd is stopped (TERM first), then every process in the namespace is killed
# children-first (the shims of the node's containerd and the containers below them), the namespace goes away with its last process, the directories are removed.
# The pod is a network namespace (holder process + the veth pair), the node's Docker bridge is a host link: both are removed.
# The pinned jars in /var/cache/bench71379578 stay (sha256 is checked at every setup).
CASE_ID="bench71379578"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

NODEPID=$(cat "$LIB_BASE/node/node.pid" 2>/dev/null)
NODENS=$(cat "$LIB_BASE/node/node.ns" 2>/dev/null)
PODNS=$(cat "$LIB_BASE/pod.ns" 2>/dev/null)
PODPID=$(cat "$LIB_BASE/pod.pid" 2>/dev/null)
protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done
in_node() { [ -n "$NODENS" ] && [ "$(sudo readlink "/proc/$1/ns/mnt" 2>/dev/null)" = "$NODENS" ]; }
kill_tree() {   # $1 = pid
    local c
    for c in $(ps -o pid= --ppid "$1" 2>/dev/null); do kill_tree "$c"; done
    sudo kill -KILL "$1" 2>/dev/null
}

if [ -n "$NODENS" ]; then
    echo "[cleanup] stopping dockerd in the node (so that it removes its containers), then every process of the node (children before parents)..."
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        in_node "$pid" && [ "$(basename "$(sudo readlink "$d/exe" 2>/dev/null)")" = dockerd ] && sudo kill -TERM "$pid" 2>/dev/null
    done
    for _ in $(seq 1 40); do
        left=""
        for d in /proc/[0-9]*; do pid=${d#/proc/}; in_node "$pid" && [ "$(basename "$(sudo readlink "$d/exe" 2>/dev/null)")" = dockerd ] && left=1; done
        [ -z "$left" ] && break; sleep 0.25
    done
    for _ in 1 2 3; do
        for d in /proc/[0-9]*; do
            pid=${d#/proc/}
            case "$protect" in *" $pid "*) continue ;; esac
            in_node "$pid" && kill_tree "$pid"
        done
        sleep 0.3
    done
fi
echo "[cleanup] the pod: processes in its network namespace, then the veth pair and the node's Docker bridge..."
for _ in 1 2 3; do
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        if [ -n "$PODNS" ] && [ "$(sudo readlink "$d/ns/net" 2>/dev/null)" = "$PODNS" ]; then kill_tree "$pid"; fi
    done
    [ -n "$PODPID" ] && [ "$PODPID" -gt 1 ] 2>/dev/null && sudo kill -KILL "$PODPID" 2>/dev/null
    sleep 0.3
done
sudo ip link del vb71h 2>/dev/null
sudo ip link del bench71br 2>/dev/null
echo "[cleanup] anything outside the node that runs from the case's directories (a daemon a solution started on the host side)..."
for _ in 1 2 3; do
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        cmd="$(sudo tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$cmd" in *"$WORK_DIR/"*|*"$LIB_BASE/"*) kill_tree "$pid" ;; esac
    done
    sleep 0.3
done
for _ in $(seq 1 20); do sudo test -d "/proc/${NODEPID:-0}" || break; sleep 0.25; done

echo "[cleanup] the host's /run/containerd: removing what a daemon on the host side left there (what setup did not find), nothing else..."
if [ -f "$LIB_BASE/hostrun.base" ] && [ -d /run/containerd ]; then
    if [ "$(sudo cat "$LIB_BASE/hostrun.base")" = "NOEXIST" ]; then
        sudo rm -rf /run/containerd
    else
        for f in $(sudo find /run/containerd/runc /run/containerd/s -mindepth 1 -maxdepth 2 2>/dev/null | sort -r); do
            sudo grep -qxF "$f" "$LIB_BASE/hostrun.base" || sudo rm -rf "$f"
        done
    fi
fi

echo "[cleanup] the cgroups dockerd made (empty ones only), the directories the node needed (only if setup created them)..."
for d in $(sudo find /sys/fs/cgroup -maxdepth 3 -type d -path '*/docker/*' -name '[0-9a-f]*' 2>/dev/null | sort -r); do sudo rmdir "$d" 2>/dev/null; done
for d in $(sudo find /sys/fs/cgroup -maxdepth 2 -name docker -type d 2>/dev/null); do
    sudo grep -qxF "$d" "$LIB_BASE/cgroup_docker.base" 2>/dev/null || sudo rmdir "$d" 2>/dev/null
done
for d in $(sudo cat "$LIB_BASE/created_dirs" 2>/dev/null); do sudo rmdir "$d" 2>/dev/null; done

echo "[cleanup] removing the directories..."
for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^($LIB_BASE|$WORK_DIR)(/|$)" | sort -r); do sudo umount -l "$m" 2>/dev/null; done
sudo rm -rf --one-file-system "$LIB_BASE" "$WORK_DIR"
echo "[cleanup] done."
exit 0
