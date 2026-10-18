#!/bin/bash
# Precondition oracle: the machine is as setup.sh recorded it, and the bad state is real and certain:
#   - the engineer's runc 1.1.3 and the machine's runc are unchanged; the container web (the one setup started) runs with its workload (heartbeat with the token)
#   - control 1: a non-interactive exec works
#   - control 2: an interactive (TTY) exec with the engineer's runc 1.1.3 fails, every time, with `open /dev/pts/N: operation not permitted`; the scope's
#     DeviceAllow has no char-pts (the entry runc 1.1.3 lost). (A newer runc's exec happens to work on such a scope: the oracle judges with 1.1.3's too.)
#   - control 3: a container made by the machine's runc (1.1.4 or newer) keeps a working TTY exec (the machine's and 1.1.3's) through systemctl daemon-reload
#     (it is removed again)
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench73434226"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import json
import os
import pty
import re
import select
import subprocess
import sys
import time

CASE = "bench73434226"
L = "/var/lib/" + CASE
RUN = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
ROOT = RUN + "/runc"
RUNC = L + "/bin/runc"
CID = "web"
SCOPE = "%s-%s.scope" % (CASE, CID)
BAD = re.compile(r"open /dev/pts/\d+: operation not permitted")
PTS_RULE = re.compile(r"char-(pts|136) ")      # the device group of the pseudo terminal slaves: runc 1.1.4 names it char-pts, newer runc char-136


def fail(msg):
    print("[precondition] FAIL: " + msg)
    sys.exit(1)


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def short(text, n=300):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[:n] + "..."


def tty_exec(runc, cid, argv, timeout=30):
    """runc exec -t CID ARGV on a real pseudo terminal; returns (exit code, output)"""
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(runc, [runc, "--root", ROOT, "exec", "-t", cid] + argv)
    out = b""
    end = time.time() + timeout
    while time.time() < end:
        if select.select([fd], [], [], 0.5)[0]:
            try:
                d = os.read(fd, 4096)
            except OSError:
                break
            if not d:
                break
            out += d
    else:
        os.kill(pid, 9)
    _, st = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(st), out.decode("utf-8", "replace")


def sh(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:4])))


def heartbeat_ok(token):
    t = read(RUN + "/data/heartbeat") or ""
    m = re.search(r"t=(\d+) pid=\d+ token=(\S+)", t)
    return bool(m) and m.group(2) == token and time.time() - int(m.group(1)) <= 4


def device_allow(scope):
    return sh(["systemctl", "show", "-p", "DeviceAllow", scope]).stdout


rec = (read(STATE + "/files.sha") or "").split()
token = (read(STATE + "/token") or "").strip()
if len(rec) != 3 or not token:
    fail("the record of setup.sh is incomplete")
sys_runc = rec[2]

# ---- the machine and the container
sha = sh(["sha256sum", RUNC, sys_runc]).stdout.split()
if len(sha) != 4 or sha[0] != rec[0] or sha[2] != rec[1]:
    fail("the runc of the engineer or the runc of the machine is not the one setup.sh recorded")
if "runc version 1.1.3" not in sh([RUNC, "--version"]).stdout:
    fail("the engineer's runc is not 1.1.3")
r = sh([RUNC, "--root", ROOT, "state", CID])
if r.returncode != 0:
    fail("the container %s does not exist: %s" % (CID, short(r.stderr)))
st = json.loads(r.stdout)
idrec = (read(STATE + "/web.id") or "").split()
stat = read("/proc/%d/stat" % st["pid"])
if st["status"] != "running" or len(idrec) != 2 or str(st["pid"]) != idrec[0] or not stat or stat.rsplit(")", 1)[1].split()[19] != idrec[1]:
    fail("the container %s is not the running one setup.sh started" % CID)
if sh(["systemctl", "show", "-p", "ActiveState", "--value", SCOPE]).stdout.strip() != "active":
    fail("the systemd scope %s is not active: the container does not run under the systemd cgroup driver" % SCOPE)
if not heartbeat_ok(token):
    fail("the workload does not write its heartbeat")

# ---- control 1: a non-interactive exec works
r = sh([RUNC, "--root", ROOT, "exec", CID, "/bin/id"])
if r.returncode != 0 or "uid=0" not in r.stdout:
    fail("control 1: a non-interactive exec should work, got rc=%d: %s" % (r.returncode, short(r.stdout + r.stderr)))
print("[precondition] control 1 ok: a non-interactive exec into %s works" % CID)

# ---- control 2: the TTY exec of runc 1.1.3 fails, every time (the scope lost its char-pts rule when systemd reloaded)
shown = ""
for i in range(2):
    rc, out = tty_exec(RUNC, CID, ["/bin/sh", "-c", "tty; exit 7"])
    if rc in (0, 7) or not BAD.search(out):
        fail("control 2: the TTY exec with the engineer's runc should fail with 'open /dev/pts/N: operation not permitted' (try %d), got rc=%d: %s" % (i + 1, rc, short(out)))
    shown = BAD.search(out).group(0)
if PTS_RULE.search(device_allow(SCOPE)):
    fail("control 2: the scope's DeviceAllow has char-pts, but the TTY exec fails")
print("[precondition] control 2 ok: the TTY exec fails with '%s' (twice), the scope's DeviceAllow has no char-pts" % shown)

# ---- control 3: a container made by the machine's runc keeps its TTY exec (also the one of runc 1.1.3) through a daemon-reload
ctl = RUN + "/ctl"
os.makedirs(ctl + "/data", exist_ok=True)
cfg = json.load(open(L + "/bundle/config.json"))
cfg["root"]["path"] = L + "/bundle/rootfs"
cfg["process"]["args"] = ["/app", "ctl-" + token]
for m in cfg["mounts"]:
    if m["destination"] == "/data":
        m["source"] = ctl + "/data"
cfg["linux"]["cgroupsPath"] = "system.slice:%s:ctl" % CASE
json.dump(cfg, open(ctl + "/config.json", "w"))
try:
    r = subprocess.run([sys_runc, "--systemd-cgroup", "--root", ROOT, "run", "-d", "ctl"], cwd=ctl, stdin=subprocess.DEVNULL,
                       stdout=open(RUN + "/ctl.log", "w"), stderr=subprocess.STDOUT, timeout=60)
    if r.returncode != 0:
        fail("control 3: the machine's runc could not start the control container: %s" % short(read(RUN + "/ctl.log")))
    time.sleep(1)
    for step in ("before the reload", "after the reload", "after a second reload"):
        if step != "before the reload":
            if sh(["systemctl", "daemon-reload"]).returncode != 0:
                fail("control 3: systemctl daemon-reload failed")
        for runc in (sys_runc, RUNC):
            rc, out = tty_exec(runc, "ctl", ["/bin/sh", "-c", "tty; echo ctl-ok; exit 7"])
            if rc != 7 or "ctl-ok" not in out or "/dev/pts/" not in out:
                fail("control 3: the TTY exec (%s) into a container made by the machine's runc should work %s, got rc=%d: %s" % (runc, step, rc, short(out)))
    if not PTS_RULE.search(device_allow(CASE + "-ctl.scope")):
        fail("control 3: the scope of a container made by the machine's runc should have the pty rule (char-pts or char-136) in DeviceAllow")
    print("[precondition] control 3 ok: a container made by the machine's runc keeps its TTY exec (runc 1.1.3's too) through two daemon-reloads")
finally:
    sh([sys_runc, "--root", ROOT, "delete", "-f", "ctl"])
    for _ in range(20):
        if sh(["systemctl", "is-active", CASE + "-ctl.scope"]).stdout.strip() != "active":
            break
        time.sleep(0.5)

if not heartbeat_ok(token) or sh([RUNC, "--root", ROOT, "list", "-q"]).stdout.split() != [CID]:
    fail("the control left something behind (or stopped the workload)")
print("[precondition] ok")
PYEOF
