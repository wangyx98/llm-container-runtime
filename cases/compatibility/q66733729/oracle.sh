#!/bin/bash
# Postcondition oracle. The engineer's Go program is compiled and run by the oracle itself, on contexts the oracle makes (a new random file under a new name, a
# new image name), so a prepared image, a pull, or a program that never builds cannot pass:
#   0. the machine is as it was: the files of the machine (configuration of containerd and BuildKit, control scripts, buildkitd and buildctl, the demo context)
#      are unchanged and both daemons run
#   1. the program in /var/lib/bench66733729/app builds (GOFLAGS=-mod=mod /var/lib/bench66733729/bin/go build) and the binary links the BuildKit Go client (github.com/moby/buildkit):
#      the build is submitted through BuildKit's API, not through an exec of buildctl or docker
#   2. TWICE, with a fresh context and image name: `sudo ./prog -context CTX -tag REF` exits 0 and prints the sha256 of the fresh payload (the output of the
#      container that the image's RUN step wrote), BuildKit's cache (buildctl du) holds the step `COPY payload-<nonce>.bin`, so this buildkitd did the build
#   3. the image REF is in the containerd namespace bench66733729, and ctr runs it there and prints the same hash; the program left no container behind

CASE_ID="bench66733729"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

python3 - <<'PYEOF'
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import secrets

CASE = "bench66733729"
L = "/var/lib/" + CASE
R = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
APP = L + "/app"
NS = "bench66733729"
CTR = L + "/bin/ctr"
BUILDCTL = L + "/bin/buildctl"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(cmd, timeout=120, cwd=None, env=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:4])))
    r.stderr = "\n".join(x for x in r.stderr.splitlines() if "DEPRECATION" not in x)
    return r


print("[oracle] 0/3 the machine must be as it was: the files of the machine unchanged, containerd and buildkitd running...")
r = subprocess.run("cd %s && sudo sha256sum -c %s/files.sha" % (L, STATE), shell=True, capture_output=True, text=True)
if r.returncode != 0:
    fail("a file of the machine changed (%s): the configuration, the scripts, buildkitd, buildctl and the demo context stay as they are" % " ".join(x.split(":")[0] for x in r.stdout.splitlines() if not x.endswith("OK")))
for n in ("containerd", "buildkitd"):
    try:
        pid = open("%s/%s.pid" % (R, n)).read().strip()
        if not os.path.isdir("/proc/%d" % int(pid)):
            raise OSError(pid)
    except (OSError, ValueError):
        fail("%s is not running" % n)

work = tempfile.mkdtemp(prefix="oracle.", dir=STATE)
try:
    print("[oracle] 1/3 the program in %s must build and its binary must link the BuildKit Go client..." % APP)
    src = os.path.join(work, "src")
    shutil.copytree(APP, src, ignore=shutil.ignore_patterns("app", "prog", "*.exe"))
    env = dict(os.environ, GOFLAGS="-mod=mod")
    prog = os.path.join(work, "prog")
    b = sh([L + "/bin/go", "build", "-o", prog, "."], timeout=900, cwd=src, env=env)
    if b.returncode != 0:
        fail("the program does not build: %s" % (b.stdout + b.stderr).strip()[-600:])
    mods = sh([L + "/bin/go", "version", "-m", prog]).stdout
    if "github.com/moby/buildkit" not in mods:
        fail("the program does not use the BuildKit Go client (github.com/moby/buildkit is not linked): the Dockerfile is built by BuildKit's API, not by an exec of buildctl or docker, and not by a pull")

    print("[oracle] 2/3 two runs with a fresh context and image name each: exit 0, the output is the sha256 of the fresh payload, BuildKit's cache holds this build...")
    for i in (1, 2):
        nonce = secrets.token_hex(6)
        ctx = os.path.join(work, "ctx%d" % i)
        os.makedirs(ctx)
        shutil.copy(os.path.join(STATE, "hasher.keep"), os.path.join(ctx, "hasher"))
        os.chmod(os.path.join(ctx, "hasher"), 0o755)
        payload = os.urandom(300000 + i)
        pname = "payload-%s.bin" % nonce
        with open(os.path.join(ctx, pname), "wb") as f:
            f.write(payload)
        with open(os.path.join(ctx, "Dockerfile"), "w") as f:
            f.write('FROM scratch\nCOPY hasher /hasher\nCOPY %s /payload.bin\nRUN ["/hasher", "make", "/payload.bin", "/payload.sha256"]\nENTRYPOINT ["/hasher", "show", "/payload.sha256"]\n' % pname)
        want = hashlib.sha256(payload).hexdigest()
        ref = "docker.io/library/bench66733729-oracle-%d:%s" % (i, nonce)
        r = sh(["sudo", "timeout", "-k", "5", "300", prog, "-context", ctx, "-tag", ref], timeout=320)
        if r.returncode != 0:
            fail("run %d: `%s -context CTX -tag %s` exited with %d: %s" % (i, os.path.basename(prog), ref, r.returncode, (r.stdout + r.stderr).strip()[-400:]))
        if want not in r.stdout.split():
            fail("run %d: the output has no line with the sha256 %s of the fresh payload; it is %r" % (i, want, r.stdout.strip()[-300:]))
        du = sh(["sudo", BUILDCTL, "du", "--verbose"], timeout=120).stdout
        if "COPY " + pname not in du:
            fail("run %d: the cache of this machine's buildkitd has no step `COPY %s`: the image was not built by this BuildKit from the context" % (i, pname))

        print("[oracle] 3/3 (run %d) the image %s must be in the containerd namespace %s and run there (ctr), and no container may be left behind..." % (i, ref, NS))
        imgs = sh(["sudo", CTR, "-n", NS, "images", "ls", "-q"]).stdout.split()
        if ref not in imgs:
            fail("run %d: the namespace %s does not list %s (it lists: %s)" % (i, NS, ref, ", ".join(imgs) or "nothing"))
        r = sh(["sudo", CTR, "-n", NS, "run", "--rm", ref, "%s-oracle-run-%d" % (CASE, i)], timeout=120)
        if r.returncode != 0 or r.stdout.strip() != want:
            fail("run %d: ctr run of %s in %s printed %r (rc=%d), not the hash %s: %s" % (i, ref, NS, r.stdout.strip()[-200:], r.returncode, want, r.stderr.strip()[-200:]))
        left = sh(["sudo", CTR, "-n", NS, "containers", "ls", "-q"]).stdout.split()
        tasks = sh(["sudo", CTR, "-n", NS, "tasks", "ls", "-q"]).stdout.split()
        if left or tasks:
            fail("run %d: the program left containers or tasks behind in %s: %s" % (i, NS, " ".join(left + tasks)))
finally:
    shutil.rmtree(work, ignore_errors=True)

print("[oracle] ALL CHECKS PASSED: the program builds the Dockerfile through BuildKit's Go client, the image lands in the containerd namespace %s, and the container prints the hash of the payload." % NS)
PYEOF
