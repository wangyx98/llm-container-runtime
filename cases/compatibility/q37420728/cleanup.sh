#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench37420728"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

echo "[cleanup] stopping the programs, the containers and the runc state of the case..."
# the programs of the case (their command line names the case; 'pkill -f' would also kill the shell that runs this script)
for sig in TERM KILL; do
    for pid in $(pgrep -x runner 2>/dev/null; pgrep -x runc 2>/dev/null; pgrep -x svc 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID"; then
            sudo kill "-$sig" "$pid" 2>/dev/null || true
        fi
    done
    sleep 0.5
done
RUNC="$LIB/bin/runc"
if [ -x "$RUNC" ] && sudo test -d "$RUN/state"; then
    for id in $(sudo "$RUNC" --root "$RUN/state" list -q 2>/dev/null); do
        sudo "$RUNC" --root "$RUN/state" kill "$id" KILL >/dev/null 2>&1
        sleep 0.3
        sudo "$RUNC" --root "$RUN/state" delete -f "$id" >/dev/null 2>&1
    done
fi
# the services of the containers (their root file system is a bundle of the case)
for pid in $(pgrep -x svc 2>/dev/null); do
    if sudo readlink "/proc/$pid/root" 2>/dev/null | grep -qF "$CASE_ID"; then sudo kill -KILL "$pid" 2>/dev/null || true; fi
done
sleep 0.3
# cgroups of the containers (cgroupsPath bench37420728/<bundle>): v2 has one directory, v1 one per controller
sudo find /sys/fs/cgroup -depth -type d \( -name "$CASE_ID" -o -path "*/$CASE_ID/*" \) -exec rmdir {} \; 2>/dev/null
echo "[cleanup] removing the case's directories (the cache $CASE_ID in /var/cache stays)..."
sudo rm -rf "$RUN" "$LIB" "$WORK_DIR"
echo "[cleanup] done"
