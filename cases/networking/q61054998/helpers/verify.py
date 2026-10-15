"""verify.py WORK : the container bench61054998 that the solution started, checked on the host (never by what the solution says).

In this order: the container runs from the bundle, and it is a NEW container (not the process that was running when the check began); its main process is the bundle's program with its
arguments unchanged; its network namespace is the host's (the inode of /proc/PID/ns/net is the one of the runc of the lab, recorded at setup); its mount namespace and its pid namespace
are not the host's (the program is process 1 of its own pid namespace: NSpid has two ids); the host service still is the process the lab started and listens on 127.0.0.1 only; then the
loopback traffic in both directions: the lab changes the nonce of the host service, and within 15 s (1) the connection from the host to 127.0.0.1:35762 must be answered by the container's
program with the NEW nonce, as process 1 (so the program read the host's loopback), the listener socket being open in that process, and (2) /data/state of the container shows reach=ok, the
new nonce and pid=1. Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import os
import re
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
if st.get("bundle") != t["bundle"]:
    fail("the container %s was not started from the bundle %s (it says %s)" % (CID, t["bundle"], st.get("bundle")))
pid = st["pid"]
if pid == t["init_pid"] and lab.proc_start(pid) == t["init_start"]:
    fail("the container %s is still the one that was started with the lab (pid %d): it keeps the network namespace it was created with; it has to be created again" % (CID, pid))
cmd = sudo_out("cat", "/proc/%d/cmdline" % pid).rstrip("\0").split("\0")
if cmd != t["args"]:
    fail("the main process of the container runs %s, not the program of the bundle %s" % (" ".join(cmd)[:80], " ".join(t["args"])))

cnet = lab.read_link("/proc/%d/ns/net" % pid)
if cnet != t["host_net"]:
    fail("the network namespace of the container is %s; the host's is %s (the one the runc of the lab runs in)" % (cnet, t["host_net"]))
for kind, label in (("mnt", "mount"), ("pid", "pid")):
    if lab.read_link("/proc/%d/ns/%s" % (pid, kind)) == os.readlink("/proc/self/ns/%s" % kind):
        fail("the %s namespace of the container is the host's: the container has lost its %s isolation" % (label, label))
nspid = re.search(r"^NSpid:\s*(.*)$", sudo_out("cat", "/proc/%d/status" % pid), re.M)
if not nspid or len(nspid.group(1).split()) < 2 or nspid.group(1).split()[-1] != "1":
    fail("the main process of the container is not process 1 of a pid namespace of its own (NSpid: %s)" % (nspid.group(1) if nspid else "?"))

try:
    lab.check(work)
except SystemExit as e:
    fail("%s (the service on the host's loopback stays as the lab made it: 127.0.0.1 only)" % e)

nonce = lab.rotate(work)
got = None
for _ in range(75):
    got = lab.fetch(t["cport"])
    if got and "nonce=%s " % nonce in got:
        break
    time.sleep(0.2)
else:
    ls = lab.listeners(t["cport"])
    fail("the host gets %s from 127.0.0.1:%d instead of an answer with the new nonce %s of the host's own service within 15 s (listeners on that port: %s)" % (
        "nothing" if got is None else "'%s'" % got[:60], t["cport"], nonce[:6] + "...", ", ".join(a for a, _ in ls) or "none"))
if "pid=1 " not in got or "reach=ok" not in got:
    fail("the answer on 127.0.0.1:%d is '%s', not the program of the container as process 1 with reach=ok" % (t["cport"], got[:60]))
ls = lab.listeners(t["cport"])
if len(ls) != 1 or ls[0][0] != "127.0.0.1":
    fail("the listener on port %d is %s, not one socket on 127.0.0.1" % (t["cport"], ", ".join(a for a, _ in ls) or "none"))
if not sudo_out("find", "/proc/%d/fd" % pid, "-lname", "socket:\\[%s\\]" % ls[0][1]).strip():
    fail("the socket that listens on 127.0.0.1:%d is not one of the container's program: something else on the host answers there" % t["cport"])
state_file = os.path.join(work, "data", "state")
body = ""
for _ in range(30):
    body = sudo_out("cat", state_file)
    if "nonce=%s\n" % nonce in body:
        break
    time.sleep(0.2)
if "reach=ok\n" not in body or "nonce=%s\n" % nonce not in body or "pid=1\n" not in body:
    fail("/data/state of the container does not show reach=ok, the new nonce and pid=1 (it has: %s)" % (body.replace("\n", " ")[:80] or "nothing"))
print("  -> OK: %s is a new container of the bundle (pid %d) running `%s`, in the host's network namespace (%s) with its own mount and pid namespaces (process 1); it read the new nonce %s from "
      "127.0.0.1:%d and the host read it back from the container's own listener on 127.0.0.1:%d" % (CID, pid, " ".join(cmd), cnet, nonce[:6] + "...", t["hport"], t["cport"]))
