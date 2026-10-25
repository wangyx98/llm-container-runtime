#!/bin/bash
# Precondition: the question's situation on the lab's node. Containerd's root is on a small loop-backed ext4 file system that is nearly full (images and the workload's data); `df` of the container's overlay
# root file system shows the same numbers as that file system (an overlay has no size of its own); the workload cannot write 60 MB more (ENOSPC). Controls: all images complete, the workload's data intact.
CASE_ID="bench65357072"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program or the configuration of the node changed since setup"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
res=$(sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import hashlib, json, os, subprocess, sys
lib, state = sys.argv[1:3]
crictl, ctr = lib + "/bin/crictl", lib + "/bin/ctr"
truth = json.load(open(state + "/truth.json"))
w = truth["workload"]
root = lib + "/containerd"


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout.strip()


mi = [l.split() for l in open("/proc/self/mountinfo") if l.split()[4] == root]
if not mi or os.stat(root).st_dev != truth["mount_dev"] or "loop" not in open("/proc/self/mountinfo").read().split(root, 1)[1].split("\n")[0]:
    print("FAIL: containerd's root is not the loop-backed file system of setup"); sys.exit(1)
c = json.loads(sh(crictl, "inspect", w["container"])[1])
if c["status"]["state"] != "CONTAINER_RUNNING" or c["status"]["startedAt"] != w["started"]:
    print("FAIL: the workload's container is not the running one of setup"); sys.exit(1)
pid = c["info"]["pid"]
f = "/proc/%d/root/tmp/work-data.bin" % pid
if hashlib.sha256(open(f, "rb").read()).hexdigest() != w["data_sha"]:
    print("FAIL: the workload's data changed"); sys.exit(1)
import re
rows = [l for l in sh(ctr, "images", "check")[1].splitlines()[1:] if not re.search(r"\scomplete \(", l)]
if rows:
    print("FAIL: an image is not complete"); sys.exit(1)
a, b = os.statvfs("/proc/%d/root" % pid), os.statvfs(root)
if (a.f_blocks, a.f_bavail) != (b.f_blocks, b.f_bavail) and abs(a.f_bavail - b.f_bavail) * a.f_frsize > 1048576:
    print("FAIL: the overlay root of the container does not report the backing file system's numbers"); sys.exit(1)
free = b.f_bavail * b.f_frsize // 1048576
if free >= 60:
    print("FAIL: the file system has %d MB free, expected it nearly full" % free); sys.exit(1)
p = "/proc/%d/root/tmp/probe.bin" % pid
try:
    with open(p, "wb") as h:
        for _ in range(60):
            h.write(os.urandom(1048576))
        h.flush(); os.fsync(h.fileno())
    full = False
except OSError as e:
    full = e.errno == 28
finally:
    if os.path.exists(p):
        os.remove(p)
if not full:
    print("FAIL: the workload could write 60 MB although only %d MB are free" % free); sys.exit(1)
print("containerd's root is a loop-backed ext4 file system with %d MB free; the container's overlay root reports the same numbers (an overlay has no size of its own); the workload cannot write 60 MB (ENOSPC); all images complete, its data intact" % free)
PY
) || fail "$res"
echo "[precondition] PASS: $res"
