#!/bin/bash
# Precondition oracle: the machine is as setup.sh recorded it, and the bad state is real and certain:
#   - the scripts of the engineer, the two packages (every file), runc and dockerd of this host are unchanged; the installed containerd is 1.4.0-1
#     (the link opt/containerd and the containerd process), dockerd runs on the socket of the case on top of that containerd, the image is loaded
#   - control 1: `docker run --rm` of the workload fails, twice, with fresh nonces; the container does not print its nonce (the text of the error
#     differs with the versions: the question shows "ttrpc: closed: unknown", others see "failed to create task ... signal: trace/breakpoint trap")
#   - control 2: the cause is the shim of the installed package: containerd-shim-runc-v2 of 1.4.0-1 dies by a signal at start (even `-v`), the one
#     of 1.4.0-2 prints its version
#   - control 3: the workload works with the other package (link to 1.4.0-2, restart): the nonce is printed, exit 0; then the link goes back to
#     1.4.0-1, restart, and docker run fails again: the state is reversible and the package is the cause, not the image, docker or runc
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench63457756"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import hashlib
import os
import secrets
import subprocess
import sys
import time

CASE = "bench63457756"
L = "/var/lib/" + CASE
R = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
IMAGE = "localhost/bench63457756/web:1"
SOCK = R + "/docker.sock"
P1 = L + "/packages/containerd-1.4.0-1"
P2 = L + "/packages/containerd-1.4.0-2"


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


def file_sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def docker(*a, timeout=120):
    return sh([L + "/bin/docker"] + list(a), timeout)


def run_workload(nonce, timeout=90):
    return docker("run", "--rm", "--network", "none", IMAGE, nonce, timeout=timeout)


def pid_of(name):
    s = (read("%s/%s.pid" % (R, name)) or "").strip()
    return int(s) if s.isdigit() and os.path.exists("/proc/" + s) else None


def exe_of(pid):
    try:
        return os.readlink("/proc/%d/exe" % pid)
    except OSError:
        return None


# ---- the record and the files
for f in ("image.id", "packages.sha", "scripts.sha", "runc.rec", "dockerd.rec"):
    if read("%s/%s" % (STATE, f)) is None:
        fail("the record %s is missing: setup.sh has not run" % f)
r = sh(["sh", "-c", "cd %s && sha256sum -c --quiet %s/scripts.sha" % (L, STATE)], 60)
if r.returncode != 0:
    fail("a script or a config file of the engineer's stack was changed: " + (r.stdout + r.stderr).strip()[:300])
r = sh(["sh", "-c", "cd %s/packages && find . -type f -exec sha256sum {} + | sort -k2 | diff - %s/packages.sha" % (L, STATE)], 120)
if r.returncode != 0:
    fail("the package cache was changed: " + (r.stdout + r.stderr).strip()[:300])
runc_path, runc_sha, runc_ver = read(STATE + "/runc.rec").split()
if file_sha(runc_path) != runc_sha:
    fail("runc of this host was changed")
dockerd_path, dockerd_sha = read(STATE + "/dockerd.rec").split()
if file_sha(dockerd_path) != dockerd_sha:
    fail("dockerd of this host was changed")
image_id = read(STATE + "/image.id").strip()
print("  %s and dockerd as recorded; scripts and packages unchanged" % runc_ver.replace("_", " "))

# ---- installed package and the processes
if os.path.realpath(L + "/opt/containerd") != P1:
    fail("the installed containerd is %s, not containerd-1.4.0-1" % os.path.realpath(L + "/opt/containerd"))
cp = pid_of("containerd")
dp = pid_of("dockerd")
if not cp or not dp:
    fail("the stack is not running (containerd pid %s, dockerd pid %s)" % (cp, dp))
if exe_of(cp) != P1 + "/containerd":
    fail("the running containerd is %s, not the installed package" % exe_of(cp))
if os.path.realpath(exe_of(dp)) != os.path.realpath(dockerd_path):
    fail("the running dockerd is %s" % exe_of(dp))
v = sh([P1 + "/containerd", "--version"]).stdout
if "v1.4.0" not in v:
    fail("the installed containerd says: " + v.strip())
print("  installed: %s" % v.strip())
r = docker("image", "inspect", "--format", "{{.Id}}", IMAGE)
if r.stdout.strip() != image_id:
    fail("the image is not the loaded one: %r vs %r (%s)" % (r.stdout.strip(), image_id, r.stderr.strip()[:200]))

# ---- control 1: docker run fails, twice
for i in (1, 2):
    nonce = "pre-%s" % secrets.token_hex(4)
    r = run_workload(nonce)
    if r.returncode == 0 or ("nonce=" + nonce) in r.stdout:
        fail("control 1: docker run worked or printed its nonce (rc=%d): %s" % (r.returncode, r.stdout.strip()[:200]))
    print("  control 1.%d: docker run fails (rc=%d): %s" % (i, r.returncode, r.stderr.strip().splitlines()[0][:160] if r.stderr.strip() else ""))
left = docker("ps", "-aq").stdout.split()
if left:
    docker("rm", "-f", *left, timeout=60)

# ---- control 2: the shims
r1 = sh([P1 + "/containerd-shim-runc-v2", "-v"], 30)
r2 = sh([P2 + "/containerd-shim-runc-v2", "-v"], 30)
if r1.returncode >= 0 and r1.returncode <= 128:
    fail("control 2: the shim of 1.4.0-1 does not die by a signal (exit %d): %s" % (r1.returncode, r1.stdout[:200]))
if r2.returncode != 0 or "v1.4.0" not in r2.stdout:
    fail("control 2: the shim of 1.4.0-2 does not run (exit %d): %s" % (r2.returncode, (r2.stdout + r2.stderr)[:200]))
sig = -r1.returncode if r1.returncode < 0 else r1.returncode - 128
print("  control 2: shim of 1.4.0-1 dies by signal %d at start, the shim of 1.4.0-2 prints its version" % sig)


# ---- control 3: the other package works, and back
def switch(pkg):
    sh(["ln", "-sfn", L + "/packages/" + pkg, L + "/opt/containerd"])
    r = sh([L + "/bin/stack", "restart"], 240)
    if r.returncode != 0:
        fail("the stack did not restart with %s: %s" % (pkg, (r.stdout + r.stderr).strip()[:300]))


switch("containerd-1.4.0-2")
nonce = "pre-%s" % secrets.token_hex(4)
r = run_workload(nonce)
if r.returncode != 0 or r.stdout.strip() != "nonce=" + nonce:
    fail("control 3: with containerd 1.4.0-2 the workload does not run (rc=%d): %s %s" % (r.returncode, r.stdout.strip()[:200], r.stderr.strip()[:300]))
print("  control 3: with containerd 1.4.0-2 the same docker run prints nonce=%s and exits 0" % nonce)
switch("containerd-1.4.0-1")
nonce = "pre-%s" % secrets.token_hex(4)
r = run_workload(nonce)
if r.returncode == 0 or ("nonce=" + nonce) in r.stdout:
    fail("control 3: after going back to 1.4.0-1 docker run works (rc=%d): %s" % (r.returncode, r.stdout.strip()[:200]))
if exe_of(pid_of("containerd") or 0) != P1 + "/containerd":
    fail("the stack does not run the installed package again after the controls")
print("  control 3: back on containerd 1.4.0-1 docker run fails again")
print("[precondition] OK: docker run fails with the installed containerd 1.4.0-1, its shim dies at start, containerd 1.4.0-2 works")
PYEOF
