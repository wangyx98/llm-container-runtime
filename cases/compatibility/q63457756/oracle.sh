#!/bin/bash
# Postcondition oracle. Everything is judged dynamically, from the daemon's answers, /proc and the containers, never from the solution's text:
#   1. nothing was bent: the scripts and config of the engineer, every file of both packages, runc and dockerd of this host are as recorded, the
#      image is the loaded one (a rebuilt package, a hand-copied shim, an edited script, a replaced runc or another image fails here)
#   2. the stack runs on the case's sockets: the containerd process and dockerd are alive, the containerd binary is the installed package
#      (the link opt/containerd) and that package is a build whose shims work (containerd-1.4.0-2: v1.4.0, the recorded files), dockerd is the host's
#   3. the same workload FIVE times, each a new container (`docker run --rm`, a fresh nonce): exit 0, the output is exactly nonce=<nonce>
#   4. identity probe: a container of the same image that waits (`docker run -d`): docker's State.Pid has a parent that is the containerd-shim-runc-v2
#      of the installed package (read from /proc/<pid>/exe, same bytes as the recorded file, started with the case's containerd socket), runc's
#      state of that container exists (below the exec root of dockerd, runtime-runc/<namespace>: the host's runc created it), containerd lists it with the runtime
#      io.containerd.runc.v2 and the image as docker has it; the container is removed, and one more run works
#   5. the daemons are the same processes before and after the runs (no restart loop) and `docker run` works at the end
# A run with `runc run`, `ctr run` or another docker daemon of this host never reaches the case's containerd and fails at 3 and 4.

CASE_ID="bench63457756"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import glob
import hashlib
import os
import secrets
import subprocess
import sys

CASE = "bench63457756"
L = "/var/lib/" + CASE
R = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
IMAGE = "localhost/bench63457756/web:1"
SOCK = R + "/docker.sock"
GOOD = L + "/packages/containerd-1.4.0-2"
NS = CASE


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


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def docker(*a, timeout=120):
    return sh([L + "/bin/docker"] + list(a), timeout)


def pid_of(name):
    s = (read("%s/%s.pid" % (R, name)) or "").strip()
    return int(s) if s.isdigit() and os.path.exists("/proc/" + s) else None


def exe_of(pid):
    try:
        return os.readlink("/proc/%d/exe" % pid)
    except OSError:
        return None


def ppid_of(pid):
    s = read("/proc/%d/stat" % pid)
    return int(s.rsplit(")", 1)[1].split()[1]) if s else None


def cmdline_of(pid):
    s = read("/proc/%d/cmdline" % pid)
    return (s or "").replace("\0", " ")


for f in ("image.id", "packages.sha", "scripts.sha", "runc.rec", "dockerd.rec"):
    if read("%s/%s" % (STATE, f)) is None:
        fail("the record %s is missing: setup.sh has not run" % f)

# ---- 1. nothing was bent
r = sh(["sh", "-c", "cd %s && sha256sum -c --quiet %s/scripts.sha" % (L, STATE)], 60)
if r.returncode != 0:
    fail("a script or a config file of the engineer's stack was changed: " + (r.stdout + r.stderr).strip()[:300])
r = sh(["sh", "-c", "cd %s/packages && find . -type f -exec sha256sum {} + | sort -k2 | diff - %s/packages.sha" % (L, STATE)], 120)
if r.returncode != 0:
    fail("a file of the package cache was changed, added or removed: " + (r.stdout + r.stderr).strip()[:300])
runc_path, runc_sha, runc_ver = read(STATE + "/runc.rec").split()
if file_sha(runc_path) != runc_sha:
    fail("runc of this host was changed")
dockerd_path, dockerd_sha = read(STATE + "/dockerd.rec").split()
if file_sha(dockerd_path) != dockerd_sha:
    fail("dockerd of this host was changed")
image_id = read(STATE + "/image.id").strip()
r = docker("image", "inspect", "--format", "{{.Id}}", IMAGE)
if r.stdout.strip() != image_id:
    fail("the image is not the loaded one (%r vs %r): %s" % (r.stdout.strip(), image_id, r.stderr.strip()[:200]))
print("  scripts, packages, %s, dockerd and the image are as recorded" % runc_ver.replace("_", " "))

# ---- 2. the stack
installed = os.path.realpath(L + "/opt/containerd")
cp0, dp0 = pid_of("containerd"), pid_of("dockerd")
if not cp0 or not dp0:
    fail("the stack is not running (containerd pid %s, dockerd pid %s); `docker run` needs both" % (cp0, dp0))
cexe = exe_of(cp0)
if cexe != installed + "/containerd":
    fail("the running containerd (%s) is not the installed package (%s)" % (cexe, installed))
if installed != GOOD:
    fail("the installed package is %s: its shims do not run (only containerd-1.4.0-2 of the cache is a good build)" % os.path.basename(installed))
v = sh([cexe, "--version"]).stdout.strip()
if "v1.4.0" not in v or "09814d48d50816305a8e6c1a4ae3e2bcc4ba725a" not in v:
    fail("the running containerd is not containerd 1.4.0-2: " + v)
if os.path.realpath(exe_of(dp0)) != os.path.realpath(dockerd_path):
    fail("the running dockerd is %s, not the dockerd of this host" % exe_of(dp0))
dcmd = cmdline_of(dp0)
if "unix://" + SOCK not in dcmd or L + "/etc/daemon.json" not in dcmd:
    fail("dockerd does not run as the engineer's stack starts it: " + dcmd[:300])
print("  stack: %s; dockerd pid %d on %s" % (v, dp0, SOCK))

# ---- 3. the workload, five new containers
for i in range(1, 6):
    nonce = "ora-%d-%s" % (i, secrets.token_hex(4))
    r = docker("run", "--rm", "--network", "none", IMAGE, nonce, timeout=120)
    if r.returncode != 0 or r.stdout != "nonce=%s\n" % nonce:
        fail("run %d: docker run rc=%d, stdout %r, stderr %r" % (i, r.returncode, r.stdout[:200], r.stderr.strip()[:300]))
print("  five docker runs: each printed its fresh nonce and exited 0")

# ---- 4. identity probe
name = "probe-" + secrets.token_hex(3)
nonce = "ora-probe-" + secrets.token_hex(4)
r = docker("run", "-d", "--network", "none", "--name", name, IMAGE, nonce, "300")
cid = r.stdout.strip()
if r.returncode != 0 or len(cid) != 64:
    fail("the probe container did not start (rc=%d): %s" % (r.returncode, r.stderr.strip()[:300]))
try:
    info = docker("inspect", "--format", "{{.State.Pid}}|{{.State.Running}}|{{.HostConfig.Runtime}}|{{.Image}}", name).stdout.strip().split("|")
    if len(info) != 4 or info[1] != "true" or not info[0].isdigit() or int(info[0]) <= 1:
        fail("the probe container is not running: %s" % "|".join(info))
    cpid = int(info[0])
    if info[2] != "runc":
        fail("the container does not use the runtime runc: %r" % info[2])
    if info[3] != image_id:
        fail("the container's image is %r, not the loaded one" % info[3])
    if "/app" not in cmdline_of(cpid):
        fail("the process %d of the container is not the workload: %r" % (cpid, cmdline_of(cpid)))
    shim = ppid_of(cpid)
    sexe = exe_of(shim) if shim else None
    if sexe != GOOD + "/containerd-shim-runc-v2":
        fail("the parent of the container's process is %s, not the containerd-shim-runc-v2 of the installed package" % (sexe,))
    if file_sha(sexe) != file_sha(GOOD + "/containerd-shim-runc-v2"):      # the package files are the recorded ones (checked at 1)
        fail("the shim is not the file of the recorded package")
    scmd = cmdline_of(shim)
    if R + "/containerd.sock" not in scmd or "-id " + cid not in scmd:
        fail("the shim was not started by the case's containerd for this container: " + scmd[:300])
    if not glob.glob("%s/docker-exec/runtime-runc/%s/%s*" % (R, NS, cid)) and not glob.glob("/run/containerd/runc/%s/%s*" % (NS, cid)):
        fail("runc has no state of the container (%s/docker-exec/runtime-runc/%s): it was not created by the host's runc through the shim" % (R, NS))
    ctr = GOOD + "/ctr"
    r = sh([ctr, "-a", R + "/containerd.sock", "-n", NS, "containers", "ls"], 30)
    row = [l for l in r.stdout.splitlines() if l.startswith(cid)]
    if not row or "io.containerd.runc.v2" not in row[0]:
        fail("containerd does not list the container with the runtime io.containerd.runc.v2: %s %s" % (r.stdout[:300], r.stderr[:200]))
    print("  probe: container %s, process %d, parent %d is %s (same bytes as the recorded file), runtime io.containerd.runc.v2, runc state present"
          % (cid[:12], cpid, shim, sexe))
finally:
    docker("rm", "-f", name, timeout=60)

# ---- 5. the same daemons, and one more run
if pid_of("containerd") != cp0 or pid_of("dockerd") != dp0:
    fail("the containerd or dockerd process changed during the oracle: the stack restarts by itself")
nonce = "ora-last-" + secrets.token_hex(4)
r = docker("run", "--rm", "--network", "none", IMAGE, nonce)
if r.returncode != 0 or r.stdout != "nonce=%s\n" % nonce:
    fail("the last docker run: rc=%d, stdout %r, stderr %r" % (r.returncode, r.stdout[:200], r.stderr.strip()[:300]))
print("[oracle] OK: docker run works through containerd 1.4.0-2 and its shim, six times, and the stack stayed the same")
PYEOF
