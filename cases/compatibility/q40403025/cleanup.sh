#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned)
CASE_ID="bench40403025"
WORK_DIR="/tmp/$CASE_ID"

protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done

echo "[cleanup] deleting the runc containers of the case (id starts with $CASE_ID, or bundle below $WORK_DIR)..."
if command -v runc >/dev/null 2>&1; then
    sudo runc list 2>/dev/null | awk 'NR > 1 {print $1, $4}' | while read -r id bundle; do
        case "$id" in "$CASE_ID"*) ;; *) case "$bundle" in "$WORK_DIR"/*) ;; *) continue ;; esac ;; esac
        sudo runc kill "$id" KILL >/dev/null 2>&1 || true
        sleep 0.2
        sudo runc delete -f "$id" >/dev/null 2>&1 || true
    done
fi

echo "[cleanup] killing processes that belong to the case (environment BENCH_CASE=$CASE_ID, or an executable below $WORK_DIR)..."
for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    case "$protect" in *" $pid "*) continue ;; esac
    if sudo grep -qaF "BENCH_CASE=$CASE_ID" "$d/environ" 2>/dev/null || sudo readlink "$d/exe" 2>/dev/null | grep -q "^$WORK_DIR/"; then
        sudo kill -KILL "$pid" 2>/dev/null
    fi
done
sleep 0.3

sudo rm -rf --one-file-system "$WORK_DIR"
echo "[cleanup] done"
