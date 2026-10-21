#!/bin/bash
set -e

CASE_ID="bench37420728"
WORK_DIR="/tmp/$CASE_ID"

echo "[precondition] the lab as recorded; the program's CombinedOutput does not return while the container runs; controls: runc itself returns at once when its output goes to a file, and the program builds here..."
OUT=$(sudo python3 - "$WORK_DIR" <<'PYEOF' 2>&1
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

CASE = "bench37420728"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
RUNC = LIB + "/bin/runc"
ROOT = RUN + "/state"                        # runc's state directory (--root)
RUNNER = LIB + "/bin/runner"
BUILD = LIB + "/bin/build"
SRC = LIB + "/src"
WORK = sys.argv[1] if len(sys.argv) > 1 else "/tmp/" + CASE


def wait_for(fn, timeout, step=0.2):
    end = time.time() + timeout
    while True:
        v = fn()
        if v:
            return v
        if time.time() >= end:
            return None
        time.sleep(step)


def run(argv, timeout=100):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", stdin=subprocess.DEVNULL)


def short(text, n=170):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 3] + "..."


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def sha_file(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        return None


def load():
    return json.load(open(os.path.join(WORK, ".bench", "truth.json")))


def runc(*args, timeout=60):
    return run([RUNC, "--root", ROOT] + list(args), timeout=timeout)


def state(cid):
    r = runc("state", cid)
    try:
        return json.loads(r.stdout) if r.returncode == 0 else None
    except ValueError:
        return None


def drop(cid):
    runc("kill", cid, "KILL")
    time.sleep(0.3)
    runc("delete", "-f", cid)


def make_bundle(name, nonce, args=None):
    """a bundle of the service below WORK: rootfs with the service program, ctl (the socket directory, bind-mounted at /ctl), config.json from the recorded template"""
    d = os.path.join(WORK, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d + "/rootfs/ctl")
    os.makedirs(d + "/ctl")
    shutil.copy(WORK + "/.bench/svc", d + "/rootfs/svc")
    os.chmod(d + "/rootfs/svc", 0o755)
    c = json.load(open(WORK + "/.bench/config.json"))
    c["process"]["args"] = args or ["/svc", nonce]
    for m in c["mounts"]:
        if m["destination"] == "/ctl":
            m["source"] = d + "/ctl"
    json.dump(c, open(d + "/config.json", "w"), indent=1)
    return d


def ping(bundle):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(3)
    try:
        s.connect(bundle + "/ctl/sock")
        return s.recv(100).decode().strip()
    except OSError as e:
        return "no answer (%s)" % e
    finally:
        s.close()


def ticks(bundle, nonce):
    return len(re.findall(r"^svc nonce=%s tick=\d+$" % re.escape(nonce), read(bundle + "/service.log") or "", re.M))


def children(pid):
    """[(pid, state letter, comm)] of the processes whose parent is pid"""
    out = []
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                st = open("/proc/%s/stat" % d).read()
            except OSError:
                continue
            comm, rest = st[st.index("(") + 1:st.rindex(")")], st[st.rindex(")") + 2:].split()
            if int(rest[1]) == pid:
                out.append((int(d), rest[0], comm))
    return out


def runc_processes():
    """processes of runc that belong to the case (command line names its state directory)"""
    out = []
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                a = open("/proc/%s/cmdline" % d, "rb").read().decode("latin-1").split("\0")
            except OSError:
                continue
            if a and a[0].endswith("/runc") and ROOT in a:
                out.append(int(d))
    return out


def start_runner(binary, bundle, cid, hold, out):
    """the runner as a test driver runs it: output to a FILE (a pipe of this process would be inherited by whatever the runner leaves behind)"""
    f = open(out, "w")
    return subprocess.Popen([binary, RUNC, ROOT, bundle, cid, str(hold)], stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, cwd="/tmp")


def is_go_binary(path):
    try:
        return b"\xff Go buildinf:" in open(path, "rb").read()
    except OSError:
        return False


def fail(msg):
    print("[precondition] FAIL: " + msg)
    sys.exit(1)


t = load()
# the lab as recorded
if sha_file(RUNC) != t["runc_sha"] or sha_file(WORK + "/.bench/svc") != t["svc_sha"] or sha_file(BUILD) != t["build_sha"]:
    fail("runc, the service or bin/build is not the one of setup.sh")
if sha_file(SRC + "/main.go") != t["runner_src_sha"] or sha_file(RUNNER) != t["runner_sha"]:
    fail("src/main.go or bin/runner is not the program of the question")
if not is_go_binary(RUNNER) or b"bench37420728/runner" not in open(RUNNER, "rb").read():
    fail("bin/runner is not a Go program of the module bench37420728/runner")
if "1.1." not in run([RUNC, "--version"]).stdout:
    fail("runc is not 1.1.x")
for name in ("c1", "c2"):
    drop("b37420728-" + name)

# the question: the program does not return while the container runs
nonce = os.urandom(4).hex()
b1 = make_bundle("c1", nonce)
p = start_runner(RUNNER, b1, "b37420728-c1", 0, WORK + "/c1.out")
try:
    if not wait_for(lambda: (state("b37420728-c1") or {}).get("status") == "running", 15):
        fail("the container of the program did not start (%s)" % short(read(WORK + "/c1.out") or "no output"))
    if ping(b1) != "pong nonce=%s served=1" % nonce:
        fail("the service of the container does not answer: " + ping(b1))
    time.sleep(4)
    if p.poll() is not None or (read(WORK + "/c1.out") or "").strip():
        fail("the program returned (exit %s, output: %s): the question's hang is not here" % (p.poll(), short(read(WORK + "/c1.out"))))
    if runc_processes():
        fail("runc is still running: it is not the container's output that the program waits for")
finally:
    p.kill()
    p.wait()
    drop("b37420728-c1")

# control 1: runc detached with its output in a file returns at once and the container goes on without its caller
nonce = os.urandom(4).hex()
b2 = make_bundle("c2", nonce)
logf = open(b2 + "/service.log", "ab")
t0 = time.time()
r = subprocess.run([RUNC, "--root", ROOT, "run", "-d", "b37420728-c2"], cwd=b2, stdout=logf, stderr=logf, stdin=subprocess.DEVNULL, timeout=20)
took = time.time() - t0
if r.returncode != 0 or took > 5:
    fail("control 1: runc run -d with its output in a file did not return at once (rc %d after %.1f s)" % (r.returncode, took))
if not wait_for(lambda: ticks(b2, nonce) >= 2, 8) or ping(b2) != "pong nonce=%s served=1" % nonce:
    fail("control 1: the container started by that runc does not run (service.log: %s)" % short(read(b2 + "/service.log")))
drop("b37420728-c2")

# control 2: the program can be built here
out = WORK + "/ctl-runner"
b = run([BUILD, SRC, out], timeout=300)
if b.returncode != 0 or not is_go_binary(out):
    fail("control 2: bin/build does not build the program: " + short(b.stdout + b.stderr, 300))
u = run([out])
os.remove(out)
if u.returncode != 2 or "usage" not in u.stderr:
    fail("control 2: the built program does not say its usage")
print("[precondition] OK: runc 1.1.x, the program and its build as recorded; the program's CombinedOutput does not return while the container runs and answers; runc run -d with a file as output returns at once; the program builds")
PYEOF
) || { echo "$OUT"; exit 1; }
echo "$OUT"
