#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.

CASE_ID="bench66733729"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"

# the containers and tasks of the case's containerd (all namespaces) first: a leftover task keeps a shim and mounts alive
if [ -S "$CTD_SOCK" ] && command -v ctr >/dev/null 2>&1; then
    echo "[cleanup] removing every container and task of the containerd of the case (all namespaces)..."
    for ns in $(sudo timeout -k 3 20 ctr -a "$CTD_SOCK" namespaces ls -q 2>/dev/null); do
        for t in $(sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" tasks ls -q 2>/dev/null); do
            sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" tasks kill -s SIGKILL "$t" >/dev/null 2>&1 || true
            sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" tasks delete --force "$t" >/dev/null 2>&1 || true
        done
        for c in $(sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" containers ls -q 2>/dev/null); do
            sudo timeout -k 3 20 ctr -a "$CTD_SOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
        done
    done
fi

# BuildKit, then containerd
for n in buildkitctl containerdctl; do
    if [ -x "$LIB_BASE/bin/$n" ]; then
        echo "[cleanup] stopping with $n..."
        sudo timeout -k 3 60 "$LIB_BASE/bin/$n" stop >/dev/null 2>&1 || true
    fi
done

# whatever of the case still runs: the daemons, shims, containers, a program a solution started. Matched by the executable (a file below the case's
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
        case "$exe" in "$LIB_BASE"/*|"$RUN_BASE"/*|"$WORK_DIR"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        case "$cmd" in *"$LIB_BASE/"*|*"$RUN_BASE/"*|*"$WORK_DIR/"*) sudo kill -KILL "$pid" 2>/dev/null ;; esac
    done
    sleep 0.3
done

# runc's state of the containers the case's containerd ran: below /run/containerd/runc/<namespace>, a place a host containerd shares. Only the entries that setup
# did not find there go (BuildKit's namespace "buildkit" and the program's), and a namespace directory that did not exist before when it is empty
if [ -e "$LIB_BASE/runc.before" ]; then
    for ns in buildkit "$CASE_ID"; do
        for e in /run/containerd/runc/$ns/*; do
            [ -e "$e" ] || continue
            grep -qxF "$e" "$LIB_BASE/runc.before" || sudo rm -rf --one-file-system "$e"
        done
        grep -qxF "/run/containerd/runc/$ns" "$LIB_BASE/runc.before" || sudo rmdir "/run/containerd/runc/$ns" 2>/dev/null
    done
fi
if [ -e "$LIB_BASE/run_containerd_created" ]; then sudo rm -rf --one-file-system /run/containerd; fi

# unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

echo "[cleanup] removing the state of the case..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"
echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state (the downloaded BuildKit in /var/cache/$CASE_ID is kept; the Go caches of the user are not touched)."
