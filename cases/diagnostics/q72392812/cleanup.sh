#!/bin/bash
# 不加 set -e：容器/任务可能本来就不存在，允许命令失败

CONTAINER="bench72392812"
WORK_DIR="/tmp/bench72392812"
RUNSC_ROOT="/run/containerd/runsc/default"

echo "[cleanup] attempting graceful shutdown via ctr (bounded with timeout, in"
echo "[cleanup] case a previous run left the shim wedged -- observed in practice"
echo "[cleanup] when two overlapping 'ctr run' invocations hit the same id)..."
timeout 15 sudo ctr task kill -s SIGKILL "$CONTAINER" 2>/dev/null
sleep 1
timeout 15 sudo ctr task delete "$CONTAINER" 2>/dev/null
timeout 15 sudo ctr container delete "$CONTAINER" 2>/dev/null

echo "[cleanup] checking whether that actually cleared everything..."
STILL_THERE=false
if pgrep -f "$CONTAINER" >/dev/null 2>&1; then
    STILL_THERE=true
fi
if sudo ctr containers ls 2>/dev/null | grep -q "$CONTAINER"; then
    STILL_THERE=true
fi

if [ "$STILL_THERE" = true ]; then
    echo "[cleanup] normal ctr cleanup didn't fully clear '$CONTAINER' -- the"
    echo "[cleanup] shim is likely wedged. Falling back to killing the raw OS"
    echo "[cleanup] processes and restarting containerd..."
    # Deliberately narrow: only the known gVisor-internal process names,
    # anchored so the container id must be the LAST argument on the command
    # line. A plain `pkill -9 -f "$CONTAINER"` also matches an interactive
    # `sudo ctr run ... $CONTAINER sleep infinity` client that may still be
    # attached to someone's terminal (id is not its last arg, so it's
    # excluded here) -- SIGKILLing that mid-flight can leave the terminal
    # that spawned it in a broken tty state (no echo / stuck input).
    sudo pkill -9 -f "containerd-shim-runsc-v1.*${CONTAINER}\$" 2>/dev/null || true
    sudo pkill -9 -f "runsc-sandbox.*${CONTAINER}\$" 2>/dev/null || true
    sudo pkill -9 -f "runsc-gofer.*${CONTAINER}\$" 2>/dev/null || true
    sleep 1
    sudo systemctl restart containerd 2>/dev/null || true
    sleep 2
    # restarting containerd only clears in-memory/shim state, NOT the
    # persisted container metadata record, so this still needs its own
    # explicit delete afterwards
    timeout 15 sudo ctr container delete "$CONTAINER" 2>/dev/null || true
fi

echo "[cleanup] removing host work dir (config + log files)..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] removing any stray runsc state dir for this container id..."
sudo rm -rf "${RUNSC_ROOT:?}/$CONTAINER" 2>/dev/null

echo "[cleanup] removing any stray stdio fifo dirs for this container id..."
for d in /run/containerd/fifo/*/; do
    [ -d "$d" ] || continue
    if sudo ls "$d" 2>/dev/null | grep -q "^${CONTAINER}-"; then
        sudo rm -rf "$d"
    fi
done

echo "[cleanup] done. Environment reset to clean state."
echo "[cleanup] (gVisor/runsc packages are left installed, same as other"
echo "[cleanup]  cases leave pulled images in place -- only this case's"
echo "[cleanup]  own artifacts are removed.)"
