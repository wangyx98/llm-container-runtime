#!/bin/bash
# Postcondition oracle. Everything is judged dynamically, from podman's answers, /proc and the service, never from the solution's text:
#   1. web is still THE container setup made (id, creation time, image), it is the only container, the wrapper is unchanged, keep.bin and the first
#      line of the boots file are intact (a container made again, or a data directory replaced, fails here)
#   2. web is started (by the solution, or by the oracle) and the real service answers with its token and a boots value equal to the number of
#      lines of the boots file
#   3. the programs podman really uses: the version of `podman --version` and of the conmon process of the running container (read from
#      /proc/<pid>/exe) are not the broken pair podman < 1.6.4 + conmon 2.0.3 (a cleaner of the leftover file in the background does not pass)
#   4. FIVE rounds on the same container: stop (stopped, port closed) and start (works, the service answers with boots + 1), the third round with
#      `podman restart`; the id never changes; each start leaves one more line in the boots file
#   5. at the end web runs, is the only container, and the data is intact
# The oracle stops nothing it did not start itself except web in the rounds; cleanup.sh removes everything afterwards.

CASE_ID="bench59724108"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import os
import re
import socket
import subprocess
import sys
import time
import urllib.request

CASE = "bench59724108"
L = "/var/lib/" + CASE
STATE = "/tmp/%s/.bench" % CASE
PODMAN = L + "/bin/podman"
DATA = L + "/data"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(cmd, timeout=120):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:4])))


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def pm(*a, timeout=120):
    return sh([PODMAN] + list(a), timeout)


def settle(cid, secs=40):
    # a stop or a failed start leaves processes of that container that are still finishing (conmon, the runc create it forked, its exit
    # command "podman container cleanup" which runs runc delete): the next step waits until no process mentions the container id
    me = str(os.getpid())
    for _ in range(secs * 5):
        busy = False
        for d in os.listdir("/proc"):
            if d.isdigit() and d != me:
                try:
                    with open("/proc/%s/cmdline" % d, "rb") as f:
                        if cid.encode() in f.read():
                            busy = True
                            break
                except OSError:
                    pass
        if not busy:
            return
        time.sleep(0.2)


def short(text, n=300):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[:n] + "..."


def info():
    r = pm("inspect", "--format", "{{.ID}}|{{.Created}}|{{.Image}}|{{.State.Running}}", "web")
    return r.stdout.strip().split("|") if r.returncode == 0 else None


def ids():
    return sorted(pm("ps", "-aq", "--no-trunc").stdout.split())


def http():
    try:
        return urllib.request.urlopen("http://127.0.0.1:8081/", timeout=3).read().decode()
    except Exception:
        return None


def wait_http(boots, secs=30):
    body = None
    for _ in range(secs):
        body = http()
        if body and "token=" + token in body and "boots=%d" % boots in body:
            return True
        time.sleep(1)
    return False


def port_open():
    s = socket.socket()
    s.settimeout(1)
    try:
        s.connect(("127.0.0.1", 8081))
        return True
    except OSError:
        return False
    finally:
        s.close()


def lines():
    return len((read(DATA + "/boots") or "").splitlines())


def vers(text):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", text or "")
    return tuple(int(x) for x in m.groups()) if m else None


def conmon_version(cid):
    """version of the conmon process of the container: found by its command line, asked through /proc/PID/exe"""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        cmd = (read("/proc/%s/cmdline" % pid) or "").split("\0")
        if cid in cmd and "--exit-dir" in cmd:
            r = sh(["/proc/%s/exe" % pid, "--version"], 10)
            return vers(r.stdout), short(r.stdout, 60)
    return None, ""


web_id, web_created, web_image = (read(STATE + "/web.rec") or "").strip().split("|")
token = (read(STATE + "/token") or "").strip()
first = (read(STATE + "/boots.first") or "").strip()

# ---- 1. the same container, the same data
r = sh(["sha256sum", PODMAN])
if r.stdout.split()[:1] != (read(STATE + "/wrapper.sha") or "").split():
    fail("the wrapper %s was changed" % PODMAN)
cur = info()
if not cur:
    fail("the container web does not exist any more")
if cur[:3] != [web_id, web_created, web_image]:
    fail("web is not the container setup made (a new container has another id and creation time): %s" % cur[:3])
if ids() != [web_id]:
    fail("web should be the only container of the engineer's podman: %s" % ids())
r = sh(["sha256sum", DATA + "/keep.bin"])
if r.stdout.split()[:1] != (read(STATE + "/keep.sha") or "").split():
    fail("keep.bin in the data directory changed")
if ((read(DATA + "/boots") or "").splitlines() or [""])[0] != first:
    fail("the first line of the boots file changed: the data directory is not the original one")
print("[oracle] web is the container setup made (id %s), the only container, its data is intact" % web_id[:12])

# ---- 2. web runs and the real service answers
if info()[3] != "true":
    settle(web_id)
    r = pm("start", "web")
    if r.returncode != 0:
        fail("podman start web fails: %s" % short(r.stdout + r.stderr))
if not wait_http(lines()):
    fail("the service does not answer with its token and boots=%d: %s" % (lines(), short(http() or "no answer")))
print("[oracle] web runs and the service answers (boots=%d)" % lines())

# ---- 3. the programs podman really uses
r = pm("--version")
pv = vers(r.stdout)
cv, ctext = conmon_version(web_id)
if not pv or not cv:
    fail("could not read the versions of podman (%s) and of the conmon of web (%s)" % (short(r.stdout + r.stderr), ctext))
if pv < (1, 6, 4) and cv == (2, 0, 3):
    fail("web still runs on the broken pair: podman %s with conmon %s" % (".".join(map(str, pv)), ".".join(map(str, cv))))
print("[oracle] programs in use: %s, conmon %s" % (short(r.stdout, 40), ".".join(map(str, cv))))

# ---- 4. five rounds on the same container
for i in range(1, 6):
    n = lines()
    if i == 3:
        r = pm("restart", "web")
        what = "restart"
    else:
        r = pm("stop", "web")
        what = "stop"
        if r.returncode != 0:
            fail("round %d: podman stop web failed: %s" % (i, short(r.stdout + r.stderr)))
        cur = info()
        if not cur or cur[3] != "false":
            fail("round %d: web is not stopped after podman stop" % i)
        for _ in range(15):
            if not port_open():
                break
            time.sleep(1)
        else:
            fail("round %d: the port is still open after podman stop" % i)
        settle(web_id)
        r = pm("start", "web")
        what = "stop + start"
    if r.returncode != 0:
        fail("round %d (%s): podman fails: %s" % (i, what, short(r.stdout + r.stderr)))
    if not wait_http(n + 1):
        fail("round %d (%s): the service does not answer with boots=%d after the start" % (i, what, n + 1))
    cur = info()
    if not cur or cur[:3] != [web_id, web_created, web_image] or cur[3] != "true":
        fail("round %d (%s): web is not the same running container: %s" % (i, what, cur))
    if lines() != n + 1:
        fail("round %d (%s): the boots file should have %d lines, has %d" % (i, what, n + 1, lines()))
print("[oracle] five rounds (stop + start, restart in the third) on the same container: the service answered after each start")

# ---- 5. the end state
if ids() != [web_id]:
    fail("web should be the only container: %s" % ids())
r = sh(["sha256sum", DATA + "/keep.bin"])
if r.stdout.split()[:1] != (read(STATE + "/keep.sha") or "").split() or ((read(DATA + "/boots") or "").splitlines() or [""])[0] != first:
    fail("the data of web changed during the rounds")
print("[oracle] PASS: the same container web starts again and again; data kept, service answers")
PYEOF
