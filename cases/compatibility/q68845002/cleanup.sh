#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.
# The downloaded JDKs and jars in /var/cache/bench68845002 are kept on purpose (checked against pinned sha256 by setup.sh); delete that directory by hand to free the space.

CASE_ID="bench68845002"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# the node first, the way its owner stops it: pods and containers through the CRI, then containerd; the oracle's control docker daemon (ctl) after that
if [ -S "$RUN/containerd.sock" ]; then
    CR="timeout -k 3 60 crictl --config $LIB/node/crictl.yaml --timeout 30s"
    for p in $(sudo $CR pods -q 2>/dev/null); do
        sudo $CR stopp "$p" >/dev/null 2>&1 || true
        sudo $CR rmp -f "$p" >/dev/null 2>&1 || true
    done
fi
[ -x "$LIB/bin/cachenodectl" ] && sudo "$LIB/bin/cachenodectl" stop >/dev/null 2>&1
if [ -S "$RUN/ctl.sock" ]; then
    for id in $(sudo timeout -k 3 60 docker -H "unix://$RUN/ctl.sock" ps -aq 2>/dev/null); do
        sudo timeout -k 3 60 docker -H "unix://$RUN/ctl.sock" rm -f "$id" >/dev/null 2>&1 || true
    done
fi
if [ -s "$RUN/ctl.pid" ]; then
    pid=$(cat "$RUN/ctl.pid"); sudo kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
fi

# whatever of the case still runs: containerd and its shims, dockerd, the java processes, a process a solution started. Matched by the executable (a file below the
# case's directories, or a process in a container whose root is below them) or by the case's paths on the command line; this script and its parents are never touched
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
        exe="$(readlink "$d/exe" 2>/dev/null)"
        cmd="$(sudo tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        root="$(sudo readlink "$d/root" 2>/dev/null)"
        case "$exe" in "$LIB"/*|"$RUN"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        case "$root" in "$LIB"/*|"$RUN"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        case "$cmd" in *"$LIB/"*|*"$RUN/"*|*"$WORK_DIR/"*) sudo kill -KILL "$pid" 2>/dev/null ;; esac
    done
    sleep 0.3
done

# cgroups of the case, in every hierarchy, deepest first: the pods' (the CRI plugin names them <parent>:cri-containerd:<id> for a slice parent, <parent>/<id> for a cgroupfs
# parent; the pod parent of the case is kubepods-burstable-pod6bd1d7f1_... or .../pod6bd1d7f1-...), the control docker daemon's parent, and the
# kubepods and burstable cgroups a cgroupfs-style parent leaves behind (rmdir fails, harmlessly, where a real kubelet has children there)
for h in /sys/fs/cgroup/*; do
    [ -d "$h" ] || continue
    sudo find "$h" -depth -type d \( -name '*pod6bd1d7f1*' -o -name 'bench68845002-ctl' \) -exec rmdir {} \; 2>/dev/null
    sudo find "$h" -maxdepth 2 -depth -type d \( -name burstable -o -name kubepods \) -exec rmdir {} \; 2>/dev/null
done

# unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the state of the case..."
sudo rm -rf --one-file-system "$LIB" "$RUN"
echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
