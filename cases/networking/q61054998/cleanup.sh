#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a container already gone), and every command here may fail without aborting the cleanup.

CASE_ID="bench61054998"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

echo "[cleanup] deleting this case's runc containers (the main one and the control ones: every ID of runc that starts with $CASE_ID)..."
for id in $(sudo runc list -q 2>/dev/null | grep "^$CASE_ID"); do
    [[ "$id" =~ ^bench61054998[a-z0-9-]*$ ]] || continue
    sudo timeout -k 3 30 runc delete -f "$id" >/dev/null 2>&1 || true
    sudo rm -rf "/run/runc/$id"                    # runc's state of the container (explicit path: no glob that a user who is not root cannot expand)
done

echo "[cleanup] stopping the host service and what a solution may have left running (a forwarder, another listener)..."
for pid in $(pgrep -x python3 2>/dev/null; pgrep -x socat 2>/dev/null; pgrep -x nc 2>/dev/null); do
    sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$CASE_ID" && sudo kill -9 "$pid" 2>/dev/null || true
done
sudo python3 - 35761 35762 35763 <<'PY' 2>/dev/null     # whatever listens on the lab's ports in the host's namespace (a fake listener started by stdin has no case name in its command line)
import os, sys
ports = {int(p) for p in sys.argv[1:]}
inodes = {l.split()[9] for l in open("/proc/net/tcp").read().splitlines()[1:] if l.split()[3] == "0A" and int(l.split()[1].split(":")[1], 16) in ports}
for d in os.listdir("/proc"):
    if d.isdigit() and int(d) != os.getpid():
        try:
            if any(os.readlink("/proc/%s/fd/%s" % (d, f)).split("[")[-1].rstrip("]") in inodes for f in os.listdir("/proc/%s/fd" % d) if os.readlink("/proc/%s/fd/%s" % (d, f)).startswith("socket:")):
                os.kill(int(d), 9)
        except OSError:
            pass
PY
for pid in $(pgrep -x app 2>/dev/null); do     # a container's program outlives a failed delete: it is ours if its cgroup path has the name of the case
    sudo grep -q "$CASE_ID" "/proc/$pid/cgroup" 2>/dev/null && sudo kill -9 "$pid" 2>/dev/null || true
done
sleep 0.5

echo "[cleanup] unmounting what a solution or a container left below the lab's directories (deepest first; a bind mount of a namespace file included), removing network namespace files made for the lab..."
for _ in 1 2 3; do
    awk '{print $2}' /proc/mounts | grep -e "$CASE_ID" | sort -r | while read -r m; do sudo umount "$m" >/dev/null 2>&1 || sudo umount -l "$m" >/dev/null 2>&1; done
    awk '{print $2}' /proc/mounts | grep -q -e "$CASE_ID" || break
    sleep 1
done
sudo rm -rf /run/netns/"$CASE_ID"* /run/"$CASE_ID"* /var/run/"$CASE_ID"*

echo "[cleanup] removing the cgroup directories that are left, the bundle and the work dir..."
sudo find /sys/fs/cgroup -maxdepth 8 -depth -type d -name "$CASE_ID*" -exec rmdir {} \; 2>/dev/null
sudo rm -rf --one-file-system "$LIB_BASE"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-* "/tmp/$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
