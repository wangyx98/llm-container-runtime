#!/bin/bash
# Idempotent; no 'set -e'. Removes the containerd of the case (and its shims), whatever still runs from the case's files or listens on 8080 because of a
# sample, the mounts below the case directories and the directories. The downloads in /var/cache/bench76534717 stay (pinned sha256).
CASE_ID="bench76534717"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

echo "[cleanup] stopping containerd, its shims and anything that runs from the case's files or listens on 8080..."
if [ -s "$RUN/containerd.pid" ]; then
    pid=$(cat "$RUN/containerd.pid"); sudo kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
fi
protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done
listeners=$(sudo python3 - <<'PYEOF'
import os
inodes = set()
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for line in open(f).read().splitlines()[1:]:
            c = line.split()
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) == 8080:
                inodes.add(c[9])
    except OSError:
        pass
pids = set()
if inodes:
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                for fd in os.listdir("/proc/%s/fd" % d):
                    try:
                        t = os.readlink("/proc/%s/fd/%s" % (d, fd))
                    except OSError:
                        continue
                    if t.startswith("socket:[") and t[8:-1] in inodes:
                        pids.add(d)
            except OSError:
                pass
print(" ".join(sorted(pids)))
PYEOF
)
for _ in 1 2 3; do
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        exe="$(readlink "$d/exe" 2>/dev/null)"
        cmd="$(sudo tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$exe" in "$LIB"/*|"$RUN"/*|"$WORK_DIR"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        case "$cmd" in *"$LIB/"*|*"$RUN/"*|*"$WORK_DIR/"*) sudo kill -KILL "$pid" 2>/dev/null ;; esac
    done
    for pid in $listeners; do
        case "$protect" in *" $pid "*) continue ;; esac
        sudo kill -KILL "$pid" 2>/dev/null
    done
    sleep 0.3
done

echo "[cleanup] unmounting whatever is mounted below the case directories (deepest first)..."
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the directories..."
sudo rm -rf "$LIB" "$RUN" "$WORK_DIR"
echo "[cleanup] done."
exit 0
