#!/bin/bash
# Precondition oracle: the machine is as setup.sh recorded it, and the bad state is real and certain:
#   - the engineer's programs are podman 1.6.2 and conmon 2.0.3, the wrapper is unchanged, the container web (id, creation time, image) is
#     stopped, its data (keep.bin, the boots file) is intact, the service does not answer
#   - control 1: `podman start web` fails, twice (the message differs with the timing: "container create failed (no logs from conmon): EOF",
#     or the error of a runc create that conmon left behind), nothing changes (no new line in the boots file, still stopped); the container
#     has a leftover `winsz` FIFO in its userdata directory: the fact that counts, not the text
#   - control 2: a NEW container of the same image runs fine at its first start (the engineer's programs work)
#   - control 3: that container stopped and started again fails the same way; with its `winsz` file removed the start works, and after the
#     next stop it fails again (the file is made again at every start): the cause is the leftover file that conmon 2.0.3 makes, not web's data
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench59724108"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import glob
import os
import re
import secrets
import socket
import stat
import subprocess
import sys
import time
import urllib.request

CASE = "bench59724108"
L = "/var/lib/" + CASE
RUN = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
PODMAN = L + "/bin/podman"
DATA = L + "/data"
IMAGE = "localhost/bench59724108/web:1"


def fail(msg):
    print("[precondition] FAIL: " + msg)
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


def info(name):
    r = pm("inspect", "--format", "{{.ID}}|{{.Created}}|{{.Image}}|{{.State.Running}}", name)
    return r.stdout.strip().split("|") if r.returncode == 0 else None


def ids():
    return sorted(pm("ps", "-aq", "--no-trunc").stdout.split())


def http():
    try:
        return urllib.request.urlopen("http://127.0.0.1:8081/", timeout=3).read().decode()
    except Exception:
        return None


def wait_http(token, boots, secs=30):
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


def lines(path):
    return len((read(path) or "").splitlines())


def fifos():
    # conmon --bundle is the persistent directory of the container, below --root: $L/storage/vfs-containers/<id>/userdata
    found = []
    for base in (L, RUN):
        for p in glob.glob("%s/storage/**/*" % base, recursive=True):
            try:
                if stat.S_ISFIFO(os.stat(p).st_mode):
                    found.append(p)
            except OSError:
                pass
    return found


def winsz(cid):
    for p in fifos():
        if p.endswith("/%s/userdata/winsz" % cid):
            return p
    return None


web_id, web_created, web_image = (read(STATE + "/web.rec") or "").strip().split("|")
token = (read(STATE + "/token") or "").strip()
boots0 = int((read(STATE + "/boots.count") or "0").strip())

# ---- the programs and the files
r = pm("--version")
if r.stdout.strip() != "podman version 1.6.2":
    fail("the engineer's podman should be 1.6.2, got %s" % short(r.stdout + r.stderr))
r = sh([L + "/libexec/conmon", "--version"])
if "version 2.0.3" not in r.stdout:
    fail("the engineer's conmon should be 2.0.3, got %s" % short(r.stdout + r.stderr))
r = sh(["sha256sum", PODMAN])
if r.stdout.split()[:1] != (read(STATE + "/wrapper.sha") or "").split():
    fail("the wrapper %s is not as setup left it" % PODMAN)
r = sh(["sha256sum", DATA + "/keep.bin"])
if r.stdout.split()[:1] != (read(STATE + "/keep.sha") or "").split():
    fail("keep.bin in the data directory changed")

# ---- the container web
cur = info("web")
if not cur or cur[:3] != [web_id, web_created, web_image]:
    fail("the container web is not the one setup made: %s" % cur)
if cur[3] != "false" or port_open():
    fail("web should be stopped and the port closed")
if ids() != [web_id]:
    fail("the containers of the engineer's podman are not just web: %s" % ids())
if lines(DATA + "/boots") != boots0:
    fail("the boots file should have %d line(s)" % boots0)

# ---- control 1: start fails with the question's error, changes nothing
for i in (1, 2):
    settle(web_id)
    r = pm("start", "web")
    text = r.stdout + r.stderr
    if r.returncode == 0:
        fail("control 1: podman start web (try %d) should fail, it worked: %s" % (i, short(text)))
    settle(web_id)
    if not winsz(web_id):
        fail("control 1: podman start web (try %d) failed (%s) but web has no leftover winsz FIFO in its userdata directory; FIFOs below the storage and runroot of the case: %s" % (i, short(text), fifos() or "none"))
if info("web")[3] != "false" or port_open() or lines(DATA + "/boots") != boots0:
    fail("control 1: the failed start changed something (running, port, boots file)")
print("[precondition] control 1 ok: podman start web fails twice (%s); web is stopped, its data is intact, a leftover winsz FIFO is in its userdata directory" % short(text, 140))

# ---- control 2: a new container runs at its first start
name = "ctl-" + secrets.token_hex(3)
tok = "pre-" + secrets.token_hex(4)
cdata = L + "/data-ctl"
os.makedirs(cdata, exist_ok=True)
r = pm("run", "-d", "--name", name, "--network", "host", "-v", cdata + ":/data", IMAGE, tok)
cid = (r.stdout.strip().splitlines() or [""])[-1]
try:
    if r.returncode != 0 or not re.fullmatch(r"[0-9a-f]{64}", cid):
        fail("control 2: podman run -d of a new container should work, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
    if not wait_http(tok, 1):
        fail("control 2: the service of the new container does not answer")
    print("[precondition] control 2 ok: a new container of the image runs and answers at its first start")

    # ---- control 3: the second start fails the same way; removing winsz helps for one start only
    if pm("stop", name).returncode != 0:
        fail("control 3: podman stop of the new container failed")
    settle(cid)
    r = pm("start", name)
    settle(cid)
    f = winsz(cid)
    if r.returncode == 0 or not f:
        fail("control 3: the second start of the new container should fail like web and leave a winsz FIFO, got rc=%d, winsz %s: %s" % (r.returncode, f, short(r.stdout + r.stderr)))
    os.unlink(f)
    r = pm("start", name)
    if r.returncode != 0 or not wait_http(tok, 2):
        fail("control 3: with winsz removed the start should work, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
    if pm("stop", name).returncode != 0:
        fail("control 3: podman stop failed")
    settle(cid)
    r = pm("start", name)
    settle(cid)
    if r.returncode == 0 or not winsz(cid):
        fail("control 3: after the next stop the start should fail again and winsz be there again, got rc=%d, winsz %s: %s" % (r.returncode, winsz(cid), short(r.stdout + r.stderr)))
    print("[precondition] control 3 ok: the new container fails at its second start too; removing winsz helps for one start, the file is there again after the next stop")
finally:
    pm("rm", "-f", name)
if ids() != [web_id] or port_open():
    fail("the control container was not removed")
print("[precondition] ok")
PYEOF
