#!/bin/bash
# Precondition oracle: the lab is as setup.sh left it, the failure is the one of the question, and two controls show that the missing pieces can be made here:
#   - the lab: the private containerd is the recorded process (pid, start time, configuration, socket), the image and the CNI plugins are as recorded, the host's firewall is as recorded
#   - the failure: the container some-rabbit runs in the network namespace net0 (not the host's), the program listens on 15672 in it, its host name is not my-rabbit, nothing listens on
#     port 8080 of the host, and the primary address of the host does not answer on 8080 - neither for the host nor for the other machine (the namespace client)
#   - the networks work: the container answers on its own address (10.172.12.2:15672) for the host and, through the host, for the other machine
#   - control 1 (a mapping can be made): a kernel DNAT rule for port 8081 to the container (removed again) makes the primary address answer on 8081 for both
#   - control 2 (the host name can be set): a throw-away container started with `ctr run --hostname` shows that host name inside (removed again)
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench72120811"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
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
STAGE = "precondition"
CMARK = CASE + "-control"


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
    """the answer of url, or None: asked from the host, or from the namespace ns (the other machine)"""
    if ns is None:
        try:
            return urllib.request.urlopen(url, timeout=4).read().decode()
        except Exception:
            return None
    r = sh(["nsenter", "--net=%s/netns/%s" % (R, ns), "python3", "-c", GET, url], timeout=20)
    return r.stdout if r.returncode == 0 else None


def wait_answer(url, token, ns=None, tries=20):
    for _ in range(tries):
        a = get(url, ns)
        if a is not None and token in a:
            return a
        time.sleep(0.5)
    return None


def netns_id(path):
    return sh(["nsenter", "--net=" + path, "readlink", "/proc/self/ns/net"]).stdout.strip()


try:
    st = json.load(open(STATE + "/state.json"))
except (OSError, ValueError):
    fail("the state record of setup.sh is missing or unreadable")
nonce = "nonce=" + st["nonce"]
hip = primary()
if not hip:
    fail("the host has no primary IPv4 address (no default route): the check needs one")

# --- the lab
try:
    cpid = int(open(R + "/containerd.pid").read().strip())
except (OSError, ValueError):
    fail("no pid file of the private containerd")
if cpid != st["containerd_pid"] or starttime(cpid) != st["containerd_start"]:
    fail("the private containerd is not the process setup.sh started")
cmd = open("/proc/%d/cmdline" % cpid).read().replace("\0", " ")
if "containerd" not in os.path.basename(os.readlink("/proc/%d/exe" % cpid)) or (L + "/containerd.toml") not in cmd:
    fail("pid %d is not containerd started from %s/containerd.toml" % (cpid, L))
if ctr("version").returncode != 0:
    fail("the private containerd does not answer on " + SOCK)
r = ctr("images", "ls", "name==" + st["image"])
rows = r.stdout.splitlines()
if len(rows) < 2 or rows[1].split()[2] != st["digest"]:
    fail("the image %s is not the recorded one (%s)" % (st["image"], st["digest"]))
r = sh(["sha256sum", "-c", "--quiet", STATE + "/cni.sha"], cwd=L + "/cni/bin")
if r.returncode != 0:
    fail("the CNI plugins in %s/cni/bin are not as recorded: %s" % (L, r.stdout.strip()[:200]))
for table, base in (("nat", "fw.nat.base"), ("filter", "fw.filter.base")):
    now = sh(["iptables", "-t", table, "-S"]).stdout
    if now != open(STATE + "/" + base).read():
        fail("the %s table of the host's firewall is not as setup.sh recorded it" % table)

# --- the failure
tasks = {l.split()[0]: l.split() for l in ctr("tasks", "ls").stdout.splitlines()[1:] if l.split()}
t = tasks.get("some-rabbit")
if not t or t[2] != "RUNNING" or int(t[1]) != st["task_pid"] or starttime(st["task_pid"]) != st["task_start"]:
    fail("the container some-rabbit is not the running one that setup.sh started")
pid = st["task_pid"]
info = json.loads(ctr("containers", "info", "some-rabbit").stdout or "{}")
if info.get("Image") != st["image"]:
    fail("the container some-rabbit does not use the image " + st["image"])
hostname = sh(["nsenter", "-t", str(pid), "-u", "hostname"]).stdout.strip()
if not hostname or hostname == "my-rabbit" or (info.get("Spec") or {}).get("hostname") == "my-rabbit":
    fail("the host name of the container is '%s': it must not be my-rabbit yet" % hostname)
mine = os.readlink("/proc/%d/ns/net" % pid)
if mine == os.readlink("/proc/self/ns/net"):
    fail("the container runs in the host's network namespace")
if mine != netns_id(R + "/netns/net0"):
    fail("the container is not in the namespace net0")
inside = listeners("/proc/%d/net" % pid)
if 15672 not in inside or 8080 in inside:
    fail("the program must listen on 15672 and not on 8080 in the container (listening: %s)" % sorted(inside))
if 8080 in listeners("/proc/net"):
    fail("something on the host listens on port 8080")
for who, ns in (("the host", None), ("the other machine", "client")):
    a = get("http://%s:8080/" % hip, ns)
    if a is not None:
        fail("%s already gets an answer on %s:8080: '%s'" % (who, hip, a.strip()[:80]))

# --- the networks work
cip = st["net0_ip"]
for who, ns in (("the host", None), ("the other machine", "client")):
    a = wait_answer("http://%s:15672/" % cip, nonce, ns)
    if a is None:
        fail("%s gets no answer from the container on %s:15672 (the lab network does not work; FORWARD policy of the firewall?)" % (who, cip))
    if "hostname=my-rabbit" in a:
        fail("the container answers with the host name my-rabbit already")

# --- control 1: a kernel mapping can be made (port 8081, removed again)
rule = ["-p", "tcp", "--dport", "8081", "-m", "addrtype", "--dst-type", "LOCAL", "-m", "comment", "--comment", CMARK,
        "-j", "DNAT", "--to-destination", "%s:15672" % cip]
added = []
try:
    for chain in ("PREROUTING", "OUTPUT"):
        r = sh(["iptables", "-t", "nat", "-A", chain] + rule)
        if r.returncode != 0:
            fail("control 1: iptables cannot add a DNAT rule in nat/%s: %s" % (chain, r.stderr.strip()[:200]))
        added.append(chain)
    for who, ns in (("the host", None), ("the other machine", "client")):
        if wait_answer("http://%s:8081/" % hip, nonce, ns, tries=8) is None:
            fail("control 1: with a DNAT rule for 8081, %s gets no answer on %s:8081" % (who, hip))
finally:
    for chain in added:
        sh(["iptables", "-t", "nat", "-D", chain] + rule)
if CMARK in sh(["iptables-save", "-t", "nat"]).stdout:
    fail("control 1: the DNAT rule of the control could not be removed")
if get("http://%s:8081/" % hip) is not None:
    fail("control 1: port 8081 still answers after the rule was removed")

# --- control 2: the host name can be set by ctr (a throw-away container in an empty network namespace of its own)
cid = CASE + "-ctl"
try:
    r = ctr("run", "-d", "--hostname", "probe-host", st["image"], cid)
    cpid2 = None
    for _ in range(30):
        row = {l.split()[0]: l.split() for l in ctr("tasks", "ls").stdout.splitlines()[1:] if l.split()}.get(cid)
        if row and row[2] == "RUNNING":
            cpid2 = int(row[1])
            break
        time.sleep(0.5)
    if not cpid2:
        fail("control 2: ctr run --hostname did not start a container: %s" % (r.stderr.strip()[-200:]))
    h2 = sh(["nsenter", "-t", str(cpid2), "-u", "hostname"]).stdout.strip()
    if h2 != "probe-host":
        fail("control 2: the container started with --hostname probe-host has the host name '%s'" % h2)
finally:
    ctr("tasks", "delete", "--force", cid)
    ctr("containers", "delete", cid)
if cid in ctr("containers", "ls", "-q").stdout.split():
    fail("control 2: the throw-away container could not be removed")
if "some-rabbit" not in {l.split()[0] for l in ctr("tasks", "ls").stdout.splitlines()[1:] if l.split()}:
    fail("the controls disturbed the container some-rabbit")

print("[%s] OK: some-rabbit runs in net0 with the host name '%s', no port mapping (8080 silent for the host and the other machine); the container answers on %s:15672; "
      "a DNAT mapping and ctr --hostname both work here" % (STAGE, hostname, cip))
PYEOF
