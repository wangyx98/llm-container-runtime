#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.

CASE_ID="bench45937714"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# the daemons of the case first (the engineer's, the oracle's target, the precondition's scratch daemon), with their containers
for n in src dst ctl; do
    if [ -e "$RUN/$n.sock" ]; then
        for id in $(sudo timeout -k 3 60 docker -H "unix://$RUN/$n.sock" ps -aq 2>/dev/null); do
            sudo timeout -k 3 60 docker -H "unix://$RUN/$n.sock" rm -f "$id" >/dev/null 2>&1 || true
        done
        sudo timeout -k 3 60 docker -H "unix://$RUN/$n.sock" network prune -f >/dev/null 2>&1 || true
    fi
    if [ -s "$RUN/$n.pid" ]; then
        pid=$(cat "$RUN/$n.pid"); sudo kill -TERM "$pid" 2>/dev/null
        for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    fi
done

# whatever of the case still runs: dockerd and its containerd, shims, proxies, the service, a process a solution started. Matched by the executable (a file below the case's
# directories) or by the case's paths on the command line; this script and its parents are never touched
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
        case "$exe" in "$LIB"/*|"$RUN"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        case "$cmd" in *"$LIB/"*|*"$RUN/"*|*"$WORK_DIR/"*|*"/var/backups/$CASE_ID"*) sudo kill -KILL "$pid" 2>/dev/null ;; esac
    done
    sleep 0.3
done

# bridges the case's daemons made for the network appnet (their names are br-<12 hex of the network id>: only those that carry an address of the case's pools)
for br in $(ip -o addr show 2>/dev/null | awk '$2 ~ /^br-/ && ($4 ~ /^10\.7[789]\./) {print $2}' | sort -u); do
    sudo ip link delete "$br" 2>/dev/null || true
done

# unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the state of the case and the backup a solution made..."
sudo rm -rf --one-file-system "$LIB" "$RUN" /var/backups/"$CASE_ID" /var/backups/"$CASE_ID".*
echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
