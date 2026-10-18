#!/bin/bash
# Postcondition oracle. The solution has run; the oracle itself makes the interactive (TTY) execs, with fresh nonces and exit codes, and judges:
#   - the machine: the runc of the machine is unchanged; the container web is still in runc's root of the case, runs, and is a systemd scope (the systemd cgroup driver)
#   - the original workload writes its heartbeat with the token, and keeps writing it
#   - six TTY execs ({the engineer's runc as it is now, runc 1.1.3} x {no reload, one reload, two more reloads}): each prints a fresh nonce on a /dev/pts/N and returns
#     the exit code it was given; a non-interactive exec still works with both
#   - the isolation the container had is kept: the device nodes of a loop device, a disk and a serial port are refused by the device rules, /dev/null can be opened; no administrative
#     capability; its own pid, mount, network, ipc and uts namespaces; its own tmpfs /dev and devpts
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench73434226"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import json
import os
import pty
import re
import select
import secrets
import subprocess
import sys
import time

CASE = "bench73434226"
L = "/var/lib/" + CASE
RUN = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
ROOT = RUN + "/runc"
ENG = L + "/bin/runc"           # the engineer's runc, as it is when the solution is done
PIN = STATE + "/runc-1.1.3"     # runc 1.1.3, the oracle's own copy
CID = "web"
SCOPE = "%s-%s.scope" % (CASE, CID)


def fail(msg):
    print("[oracle] FAIL: " + msg)
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


def sh(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:4])))


def tty_exec(runc, argv, timeout=30):
    """runc exec -t web ARGV on a real pseudo terminal; returns (exit code, output)"""
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(runc, [runc, "--root", ROOT, "exec", "-t", CID] + argv)
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


def heartbeat():
    m = re.search(r"t=(\d+) pid=(\d+) token=(\S+)", read(RUN + "/data/heartbeat") or "")
    return (int(m.group(1)), int(m.group(2)), m.group(3)) if m else None


rec = (read(STATE + "/files.sha") or "").split()
token = (read(STATE + "/token") or "").strip()
if len(rec) != 3 or not token:
    fail("the record of setup.sh is incomplete")
sys_runc = rec[2]

# ---- the machine, the container, the workload
if sh(["sha256sum", sys_runc]).stdout.split()[:1] != [rec[1]]:
    fail("the runc of the machine (%s) was changed" % sys_runc)
if not os.access(ENG, os.X_OK) or not re.search(r"runc version \d+\.\d+\.\d+", sh([ENG, "--version"]).stdout):
    fail("the engineer's runc (%s) is gone or is not runc" % ENG)
r = sh([PIN, "--root", ROOT, "state", CID])
if r.returncode != 0:
    fail("the container %s is not in runc's root %s: %s" % (CID, ROOT, short(r.stderr)))
state = json.loads(r.stdout)
pid = state["pid"]
if state["status"] != "running":
    fail("the container %s is %s, not running" % (CID, state["status"]))
if sh(["systemctl", "show", "-p", "ActiveState", "--value", SCOPE]).stdout.strip() != "active" or SCOPE not in (read("/proc/%d/cgroup" % pid) or ""):
    fail("the container %s does not run in the systemd scope %s (the systemd cgroup driver is part of the setup)" % (CID, SCOPE))
hb = heartbeat()
if not hb or hb[2] != token or time.time() - hb[0] > 4:
    fail("the original workload (token %s) does not write its heartbeat in %s" % (token, CID))
time.sleep(2.5)
hb2 = heartbeat()
if not hb2 or hb2[2] != token or hb2[0] <= hb[0]:
    fail("the original workload does not keep writing its heartbeat")
print("[oracle] the container %s runs in %s; the workload writes its heartbeat (token %s)" % (CID, SCOPE, token))

# ---- six fresh TTY execs, through systemctl daemon-reload
steps = [("no reload", 0), ("one reload", 1), ("three reloads", 2)]
code = 3
for step, reloads in steps:
    for _ in range(reloads):
        if sh(["systemctl", "daemon-reload"]).returncode != 0:
            fail("systemctl daemon-reload failed")
    for runc, who in ((ENG, "the engineer's runc"), (PIN, "runc 1.1.3")):
        code += 1
        nonce = "n" + secrets.token_hex(8)
        rc, out = tty_exec(runc, ["/bin/sh", "-c", "tty; echo %s; exit %d" % (nonce, code)])
        if rc != code or nonce not in out or not re.search(r"/dev/pts/\d+", out):
            fail("a TTY exec with %s (%s) should print the nonce on a /dev/pts/N and exit %d, got rc=%d: %s" % (who, step, code, rc, short(out)))
print("[oracle] six fresh TTY execs (the engineer's runc and runc 1.1.3, with no reload, one and three reloads): nonce, /dev/pts/N and exit code are right")

# ---- the non-interactive exec still works
for runc, who in ((ENG, "the engineer's runc"), (PIN, "runc 1.1.3")):
    r = sh([runc, "--root", ROOT, "exec", CID, "/bin/id"])
    if r.returncode != 0 or "uid=0" not in r.stdout:
        fail("a non-interactive exec with %s should work, got rc=%d: %s" % (who, r.returncode, short(r.stdout + r.stderr)))

# ---- the isolation is kept
def probe(path):
    r = sh([PIN, "--root", ROOT, "exec", CID, "/probe", path])
    return r.returncode, r.stdout.strip()


for path, what in (("/probe-dev/loop0", "a loop device (b 7:0)"), ("/probe-dev/sda", "a disk (b 8:0)"), ("/probe-dev/ttyS0", "a serial port (c 4:64)")):
    rc, out = probe(path)
    if out != "denied: Operation not permitted":
        fail("the isolation is gone: a device node of %s is not refused by the device rules in the container (%s)" % (what, out or "no output"))
rc, out = probe("/probe-dev/null")
if out != "opened":
    fail("/dev/null (c 1:3) cannot be opened in the container: %s" % out)
status = read("/proc/%d/status" % pid) or ""
capeff = int(re.search(r"CapEff:\s*([0-9a-f]+)", status).group(1), 16)
if capeff & (1 << 21):
    fail("the container's first process has CAP_SYS_ADMIN (it is not the container it was)")
for ns in ("pid", "mnt", "net", "ipc", "uts"):
    if os.readlink("/proc/%d/ns/%s" % (pid, ns)) == os.readlink("/proc/1/ns/%s" % ns):
        fail("the container shares the %s namespace of the host" % ns)
mounts = {}
for ln in (read("/proc/%d/mountinfo" % pid) or "").splitlines():
    f = ln.split()
    mounts[f[4]] = (f[3], ln.split(" - ")[1].split()[0])
if mounts.get("/dev") != ("/", "tmpfs") or mounts.get("/dev/pts", ("", ""))[1] != "devpts" or mounts["/dev/pts"][0] != "/":
    fail("the container does not have its own tmpfs /dev and devpts: %s" % {k: v for k, v in mounts.items() if k.startswith("/dev")})
print("[oracle] isolation kept (a loop device, a disk and a serial port are refused by the device rules, /dev/null opens; no CAP_SYS_ADMIN; own namespaces, /dev and devpts)")

# ---- the original workload is still fine after all of it
hb3 = heartbeat()
if not hb3 or hb3[2] != token or time.time() - hb3[0] > 4 or sh([PIN, "--root", ROOT, "state", CID]).returncode != 0:
    fail("the original workload stopped writing its heartbeat during the checks")
print("[oracle] ok")
PYEOF
