#!/bin/bash
# Postcondition oracle. Judged on what the kernel and the processes really do, not on the commands of the solution:
#   1. the lab is still the lab: the private containerd is the process setup.sh started (not restarted), the image has the recorded digest, the CNI plugins are as recorded, the other
#      machine (namespace client) still has its address, every firewall rule of the baseline is still there (nothing flushed or replaced)
#   2. the container: some-rabbit is a NEW container (another process than the one setup.sh started; the host name of a running container cannot be changed) from the recorded image,
#      running the recorded program (the bytes of /proc/PID/exe), with the host name my-rabbit in its spec and in its UTS namespace
#   3. the network: its network namespace is not the host's, the program listens on 15672 in it and not on 8080
#   4. a published port made by the kernel: no socket of the host listens on 8080 (no proxy, no fake server), and the primary address of the host (source of the default route)
#      answers on 8080 with the line of the container ("mgmt hostname=my-rabbit nonce=<token of the image>") three times for the host's own clients and three times for the other
#      machine, which comes in through the bridge (a rule for the host's own traffic only is not a published port)
# cleanup.sh removes everything afterwards.

CASE_ID="bench72120811"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

CASE = "bench72120811"
L = "/var/lib/" + CASE
R = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
SOCK = R + "/containerd.sock"
STAGE = "oracle"


def fail(msg):
    print("[%s] FAIL: %s" % (STAGE, msg))
    sys.exit(1)


def sh(cmd, timeout=60, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out")


def ctr(*a, timeout=60):
    return sh(["ctr", "--address", SOCK, "-n", "default"] + list(a), timeout=timeout)


def starttime(pid):
    try:
        s = open("/proc/%s/stat" % pid).read()
        return int(s[s.rindex(")") + 2:].split()[19])
    except (OSError, ValueError):
        return None


def listeners(path):
    ports = set()
    for f in ("tcp", "tcp6"):
        try:
            for line in open("%s/%s" % (path, f)).read().splitlines()[1:]:
                c = line.split()
                if c[3] == "0A":
                    ports.add(int(c[1].rsplit(":", 1)[1], 16))
        except OSError:
            pass
    return ports


def primary():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


GET = "import sys,urllib.request;sys.stdout.write(urllib.request.urlopen(sys.argv[1],timeout=4).read().decode())"


def get(url, ns=None):
    if ns is None:
        try:
            return urllib.request.urlopen(url, timeout=4).read().decode()
        except Exception:
            return None
    r = sh(["nsenter", "--net=%s/netns/%s" % (R, ns), "python3", "-c", GET, url], timeout=20)
    return r.stdout if r.returncode == 0 else None


try:
    st = json.load(open(STATE + "/state.json"))
except (OSError, ValueError):
    fail("the state record of setup.sh is missing or unreadable")
want = "mgmt hostname=my-rabbit nonce=%s\n" % st["nonce"]
hip = primary()
if not hip:
    fail("the host has no primary IPv4 address (no default route)")

# --- 1. the lab
try:
    cpid = int(open(R + "/containerd.pid").read().strip())
except (OSError, ValueError):
    fail("no pid file of the private containerd")
if cpid != st["containerd_pid"] or starttime(cpid) != st["containerd_start"]:
    fail("the private containerd was restarted or replaced")
if ctr("version").returncode != 0:
    fail("the private containerd does not answer on " + SOCK)
rows = ctr("images", "ls", "name==" + st["image"]).stdout.splitlines()
if len(rows) < 2 or rows[1].split()[2] != st["digest"]:
    fail("the image %s is not the recorded one" % st["image"])
r = sh(["sha256sum", "-c", "--quiet", STATE + "/cni.sha"], cwd=L + "/cni/bin")
if r.returncode != 0:
    fail("the CNI plugins in %s/cni/bin were changed" % L)
r = sh(["nsenter", "--net=%s/netns/client" % R, "hostname", "-I"])
if r.returncode != 0 or st["client_ip"] not in r.stdout.split():
    fail("the namespace client (the other machine) lost its address %s" % st["client_ip"])
for table, base in (("nat", "fw.nat.base"), ("filter", "fw.filter.base")):
    now = set(sh(["iptables", "-t", table, "-S"]).stdout.splitlines())
    gone = [l for l in open(STATE + "/" + base).read().splitlines() if l not in now]
    if gone:
        fail("a firewall rule of the host's %s table is gone (flushed or replaced): %s" % (table, gone[0][:120]))

# --- 2. the container
if "some-rabbit" not in ctr("containers", "ls", "-q").stdout.split():
    fail("there is no container some-rabbit")
info = json.loads(ctr("containers", "info", "some-rabbit").stdout or "{}")
if info.get("Image") != st["image"]:
    fail("the container some-rabbit uses the image '%s', not %s" % (info.get("Image"), st["image"]))
row = {l.split()[0]: l.split() for l in ctr("tasks", "ls").stdout.splitlines()[1:] if l.split()}.get("some-rabbit")
if not row or row[2] != "RUNNING":
    fail("the container some-rabbit is not running (task: %s)" % (row[2] if row else "none"))
pid = int(row[1])
if pid == st["task_pid"] and starttime(pid) == st["task_start"]:
    fail("the container some-rabbit is still the one that setup.sh started: it was not made again (the host name of a running container cannot be changed)")
try:
    if hashlib.sha256(open("/proc/%d/exe" % pid, "rb").read()).hexdigest() != st["srv_sha"]:
        fail("the program of the container is not the program of the image")
except OSError:
    fail("cannot read the program of the container (pid %d)" % pid)
spec_host = (info.get("Spec") or {}).get("hostname")
uts_host = sh(["nsenter", "-t", str(pid), "-u", "hostname"]).stdout.strip()
if spec_host != "my-rabbit" or uts_host != "my-rabbit":
    fail("the host name of the container is '%s' (spec: '%s'), it must be my-rabbit" % (uts_host, spec_host))

# --- 3. the network
if os.readlink("/proc/%d/ns/net" % pid) == os.readlink("/proc/self/ns/net"):
    fail("the container runs in the host's network namespace")
inside = listeners("/proc/%d/net" % pid)
if 15672 not in inside:
    fail("the program does not listen on 15672 in the container (listening: %s)" % sorted(inside))
if 8080 in inside:
    fail("the program listens on 8080 in the container: the container's port was changed instead of mapping port 8080 to 15672")

# --- 4. a published port made by the kernel
if 8080 in listeners("/proc/net"):
    fail("a socket of the host listens on port 8080: a published port must be made by the kernel's firewall, not by a process of the host")
url = "http://%s:8080/" % hip
for who, ns in (("the host", None), ("the other machine", "client")):
    ok = 0
    first = None
    for i in range(3):
        a = None
        for _ in range(20 if i == 0 else 4):
            a = get(url, ns)
            if a is not None:
                break
            time.sleep(0.5)
        first = first if first is not None else a
        if a == want:
            ok += 1
        else:
            first = a
            break
    if ok != 3:
        if first is None:
            extra = " (for the other machine: a rule only for the host's own traffic is not enough, the traffic that arrives through the bridge needs one too)" if ns else ""
            fail("%s gets no answer from %s%s" % (who, url, extra))
        fail("%s gets '%s' from %s, expected '%s'" % (who, first.strip()[:100], url, want.strip()))

print("[%s] OK: some-rabbit (pid %d) is a new container from the recorded image with the host name my-rabbit, in a network namespace of its own with the program on 15672; "
      "nothing of the host listens on 8080 and %s:8080 answers with the container's line for the host and for the other machine" % (STAGE, pid, hip))
PYEOF
