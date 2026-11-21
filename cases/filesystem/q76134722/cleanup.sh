#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not
# running), and every command here may fail without aborting the cleanup.

CASE_ID="bench76134722"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CTD_SOCK="$RUN_BASE/containerd.sock"

# The case's own processes, found by what they are, not by who started them: a process (not this script and not one of its parents) whose command line
# names the case, or whose working directory, executable or open files are below the case's directories. That takes anything a solution left running (a poller, a server,
# a loop, its sleeps), whatever it is called, and the containerd of the case with its shims. Signal $1.
kill_ours() {
    sudo python3 - "$1" "$CASE_ID" "$RUN_BASE" "$LIB_BASE" "$WORK_DIR" <<'PYEOF'
import os, signal, sys
sig = getattr(signal, "SIG" + sys.argv[1]); cid = sys.argv[2]; dirs = tuple(sys.argv[3:])
skip = set()
p = os.getpid()
while p > 1:                                   # this process and its parents (the shell that runs the cleanup, the harness)
    skip.add(p)
    try: p = int(open("/proc/%d/stat" % p).read().rsplit(")", 1)[1].split()[1])
    except Exception: break
def ours(pid):
    try: cmd = open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
    except Exception: return False
    if cid in cmd: return True
    for link in ("cwd", "exe"):
        try:
            if os.readlink("/proc/%d/%s" % (pid, link)).startswith(dirs): return True
        except Exception: pass
    try:
        for fd in os.listdir("/proc/%d/fd" % pid):
            try:
                if os.readlink("/proc/%d/fd/%s" % (pid, fd)).startswith(dirs): return True
            except Exception: pass
    except Exception: pass
    return False
for d in os.listdir("/proc"):
    if d.isdigit() and int(d) not in skip and ours(int(d)):
        try: os.kill(int(d), sig)
        except Exception: pass
PYEOF
}

# the pods and containers of the private containerd: their ids are collected first (to remove their cgroups afterwards), the pods are stopped and removed
# through the CRI so that the runtime lets go of their mounts
IDS=""
if [ -S "$CTD_SOCK" ] && command -v crictl >/dev/null 2>&1; then
    echo "[cleanup] removing every pod and container of the private containerd..."
    CR="sudo timeout -k 3 20 crictl --runtime-endpoint unix://$CTD_SOCK --image-endpoint unix://$CTD_SOCK"
    IDS="$($CR ps -a -q 2>/dev/null) $($CR pods -q 2>/dev/null)"
    for p in $($CR pods -q 2>/dev/null); do $CR stopp "$p" >/dev/null 2>&1 || true; done
    for p in $($CR pods -q 2>/dev/null); do $CR rmp -f "$p" >/dev/null 2>&1 || true; done
fi

echo "[cleanup] stopping the processes of the case (anything a solution left running (a poller, a server), this case's containerd and its shims)..."
# systemd units a solution may have made (named bench76134722-*; the task says so)
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    for u in $(systemctl list-units --all --plain --no-legend "$CASE_ID-*" 2>/dev/null | awk '{print $1}'); do sudo systemctl stop "$u" >/dev/null 2>&1 || true; done
    sudo find /etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system -maxdepth 2 -name "$CASE_ID-*" -exec rm -rf {} + 2>/dev/null || true
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
fi
kill_ours STOP          # freeze them first: a process that restarts its helpers cannot outrun the kill
kill_ours KILL
sleep 0.5

# Unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything:
# rm -rf must never walk into a live mount (overlay mounts of a container, shm).
for _ in 1 2 3; do
    for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR" $(ls -d "$WORK_DIR"-* 2>/dev/null); do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the cgroups containerd made for the pods and containers (they are named by the ids); empty now that the processes are gone
for id in $IDS; do
    [ ${#id} -ge 16 ] || continue
    sudo find /sys/fs/cgroup -maxdepth 8 -depth -type d -name "*$id*" -exec rmdir {} \; 2>/dev/null || true
done

echo "[cleanup] removing the containerd state and the work dir..."
sudo rm -rf --one-file-system "$RUN_BASE" "$LIB_BASE"
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
