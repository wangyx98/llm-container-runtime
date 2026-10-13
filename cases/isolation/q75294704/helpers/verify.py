"""verify.py WORK : the postcondition, from the host's point of view (run as root by oracle.sh with sudo).

The solution has to leave a container `bench75294704-scan` running (in the containerd namespace bench75294704, from the lab's image, program /scan) that sees the volume without being privileged.
Checks, in order (the first wrong one ends it with one short line; variable details last):
  1 the container has a RUNNING task; its container record names the lab's image; its main process is /scan, the very binary the lab built (sha256 of /proc/PID/exe);
  2 it is not privileged: its effective capabilities are within those of a plain container the lab starts for comparison (nothing added, not all of them);
  3 its /dev has no block device node for any other device than the volume (the lab has a decoy disk and the host has other loop devices): every block node there has the volume's major:minor;
  4 the volume is really read through the container's own view: the lab writes a NEW random label with tune2fs on the host, sends SIGUSR1 to the program, and the line in the container's
    /tmp/scan-result.txt must be `OK <kernel name> ext4 <new label>` (twice, with two labels); an ERROR line shows what /scan could not do;
  5 it is still the same running task afterwards."""
import hashlib
import json
import os
import secrets
import signal
import stat
import sys
import time

work = sys.argv[1]
bench = os.path.join(work, ".bench")
sys.path.insert(0, bench)
import lab   # noqa: E402

t = lab.load(work)
CID = "bench75294704-scan"
vol = t["vol"]


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


pid = lab.task_pid(CID)
if pid is None:
    names = lab.ctr("containers", "ls", "-q").stdout.split()
    if CID in names:
        fail("the container %s exists in the namespace %s but has no running task" % (CID, lab.NS))
    fail("there is no container %s in the containerd namespace %s (it has %d)" % (CID, lab.NS, len(names)))
info = json.loads(lab.ctr("containers", "info", CID).stdout or "{}")
if info.get("Image") != t["ref"]:
    fail("the container runs the image %s, not %s" % (info.get("Image"), t["ref"]))
try:
    cmdline = open("/proc/%d/cmdline" % pid, "rb").read().split(b"\0")[0].decode()
    exe = hashlib.sha256(open("/proc/%d/exe" % pid, "rb").read()).hexdigest()
except OSError as e:
    fail("the main process of the container cannot be read (%s)" % e)
if cmdline != "/scan" or exe != t["scan_sha"]:
    fail("the main process of the container is %s, not the program /scan of the image" % cmdline[:80])

# a plain container, for the capabilities a container normally has
ctl = "%s-ctl-%s" % (lab.CASE, secrets.token_hex(3))
try:
    cpid = lab.run_container(ctl)
    plain = lab.cap_eff(cpid) if cpid else None
finally:
    lab.stop(ctl)
if plain is None:
    fail("lab error: the comparison container did not run")
caps = lab.cap_eff(pid)
if caps & ~plain:
    extra = [str(b) for b in range(64) if (caps & ~plain) >> b & 1]
    fail("the container has capabilities a plain container does not have (the numbers: %s; it looks privileged or has capabilities added)" % ",".join(extra))

# device nodes
dev = "/proc/%d/root/dev" % pid
other = []
for name in sorted(os.listdir(dev)):
    try:
        st = os.stat(os.path.join(dev, name))
    except OSError:
        continue
    if stat.S_ISBLK(st.st_mode) and (os.major(st.st_rdev), os.minor(st.st_rdev)) != (vol["major"], vol["minor"]):
        other.append(name)
if other:
    fail("the container has device nodes of other devices in /dev (%d, for example %s)" % (len(other), other[0]))

# the volume, read through the container's own view
for rnd in (1, 2):
    label = "NEW%d-%s" % (rnd, secrets.token_hex(3))
    r = lab.run("tune2fs", "-L", label, "/dev/" + vol["kname"])
    if r.returncode != 0:
        fail("lab error: tune2fs failed: %s" % r.stderr.strip()[-100:])
    os.kill(pid, signal.SIGUSR1)
    time.sleep(0.3)
    line = lab.result(pid, wait_for=label)
    want = "OK %s ext4 %s" % (vol["kname"], label)
    if line != want:
        if not line:
            fail("the program wrote no result file in the container")
        if line.startswith("ERROR"):
            fail("the program in the container cannot scan the volume (it would be %s): %s" % (vol["kname"], line[6:200]))
        fail("after the label of the volume was changed to %s the program says: %s" % (label, line[:120]))
if lab.task_pid(CID) != pid:
    fail("the container was restarted during the check")
print("  -> OK: %s runs /scan as an ordinary container (no extra capabilities), /dev has only the volume (%s, %d:%d), and the program read two new labels from it" % (CID, vol["kname"], vol["major"], vol["minor"]))
