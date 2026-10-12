"""verify.py WORK : the container bench66547508 that the solution started, checked on the host (never by what the solution says).

In this order: the container runs, its main process is the bundle's program (`/app run PORT`); its user namespace: the maps start with `0 5000` for users and groups (root of the container is host
id 5000), it is a user namespace of its own and the process really runs as host uid/gid 5000; its network namespace is the host's one (the inode of /proc/PID/ns/net is that of this process);
/sys: either there is no mount at /sys in the container, or it is the real sysfs mounted read-only (a tmpfs, or a read-write mount, is not); then the nonce: the lab changes the nonce of the
service on the host's loopback, and /data/state (WORK/data/state on the host) must show the new one within 15 s, written by the container's program (owner 5000, uid=0 and gid=0 as the program
saw them). Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys
import time

work = sys.argv[1]
bench = os.path.join(work, ".bench")
sys.path.insert(0, bench)
import lab  # noqa: E402

CID = lab.CASE
t = lab.load(work)


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


def sudo_out(*cmd):
    return subprocess.run(["sudo", *cmd], capture_output=True, text=True).stdout


st = lab.state(CID)
if not st:
    fail("there is no container %s (sudo runc state %s finds nothing)" % (CID, CID))
if st["status"] != "running":
    fail("the container %s is %s, not running" % (CID, st["status"]))
pid = st["pid"]
cmd = sudo_out("cat", "/proc/%d/cmdline" % pid).rstrip("\0").split("\0")
if cmd != t["args"]:
    fail("the main process of the container runs %s, not the program of the bundle %s" % (" ".join(cmd)[:80], " ".join(t["args"])))

hid = str(t["host_id"])
for name in ("uid_map", "gid_map"):
    m = sudo_out("cat", "/proc/%d/%s" % (pid, name)).split()
    if len(m) < 3 or m[0] != "0" or m[1] != hid:
        fail("the %s of the container is '%s'; root of the container must be host id %s ('0 %s ...')" % (name, " ".join(m), hid, hid))
if lab.read_link("/proc/%d/ns/user" % pid) == os.readlink("/proc/self/ns/user"):
    fail("the container is in the user namespace of the host")
uid = sudo_out("stat", "-c", "%u:%g", "/proc/%d" % pid).strip()
if uid != "%s:%s" % (hid, hid):
    fail("the main process of the container runs as host uid:gid %s, not %s:%s" % (uid, hid, hid))

cnet, hnet = lab.read_link("/proc/%d/ns/net" % pid), os.readlink("/proc/self/ns/net")
if cnet != hnet:
    fail("the network namespace of the container is %s; the host's is %s" % (cnet, hnet))

sys_mount = None
for line in sudo_out("cat", "/proc/%d/mountinfo" % pid).splitlines():
    f = line.split()
    if f[4] == "/sys":
        sys_mount = (f[5], f[f.index("-") + 1])
if sys_mount is not None:
    opts, fstype = sys_mount
    if fstype != "sysfs":
        fail("/sys in the container is a %s, not the host's sysfs" % fstype)
    if "ro" not in opts.split(","):
        fail("/sys in the container is mounted read-write (%s)" % opts.split(",")[0])

old = open(os.path.join(work, "data", "state")).read() if os.path.exists(os.path.join(work, "data", "state")) else ""
nonce = lab.rotate(work)
state_file = os.path.join(work, "data", "state")
got = ""
for _ in range(75):
    if os.path.exists(state_file):
        got = open(state_file).read()
        if "nonce=%s\n" % nonce in got:
            break
    time.sleep(0.2)
else:
    fail("/data/state of the container does not show the new nonce of the host's service within 15 s (it has: %s)" % (got.replace("\n", " ")[:80] or "nothing"))
s = os.stat(state_file)
if (s.st_uid, s.st_gid) != (t["host_id"], t["host_id"]):
    fail("%s belongs to %d:%d on the host, not to %s:%s" % (state_file, s.st_uid, s.st_gid, hid, hid))
if "uid=0\ngid=0\n" not in got:
    fail("the program in the container saw other ids than 0:0 (%s)" % got.replace("\n", " ")[:60])
print("  -> OK: %s runs `%s` with root = host %s:%s (own user namespace), in the host's network namespace (%s), /sys %s; it read the new nonce %s from 127.0.0.1:%d" % (
    CID, " ".join(cmd), hid, hid, hnet, "not mounted" if sys_mount is None else "is the host's sysfs, read-only", nonce[:6] + "...", t["port"]))
