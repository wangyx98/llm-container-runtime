#!/bin/bash
set -e

CASE_ID="bench37420728"
WORK_DIR="/tmp/$CASE_ID"

echo "[oracle] the program of bin/runner: returns when runc has started the container, the container (its output in service.log) runs after the program exited, no runc left; a container that cannot start is reported..."
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


RETURN_WITHIN = 8        # seconds the program may take to return from the start of a container
HOLD = 6                 # seconds the program stays alive after that in the first run (the rest of a bigger program)
ids = []


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def first_line(path):
    text = read(path) or ""
    return text.split("\n")[0] if "\n" in text else None


def container_runs(bundle, cid, nonce, what):
    """the container is running, answers with its nonce, and its output goes on growing in service.log"""
    st = state(cid)
    if not st or st.get("status") != "running":
        fail("%s: the container %s is not running (runc state: %s)" % (what, cid, short(json.dumps(st))))
    a = ping(bundle)
    if not a.startswith("pong nonce=%s " % nonce):
        fail("%s: the service does not answer with its nonce: %s" % (what, a))
    t1 = ticks(bundle, nonce)
    time.sleep(2.5)
    t2 = ticks(bundle, nonce)
    if t2 < t1 + 1 or t2 < 1:
        fail("%s: the output of the service does not grow in service.log (%d -> %d lines 'svc nonce=%s tick=N'; the file has: %s)" % (what, t1, t2, nonce, short(read(bundle + "/service.log") or "nothing")))
    if not ping(bundle).startswith("pong nonce=%s " % nonce):
        fail("%s: the service stopped answering" % what)


def finish(p):
    if p.poll() is None:
        p.kill()
    p.wait()


t = load()
# the program is a Go program of the module, not the one of the question, and what it needs is the one of setup.sh
if sha_file(RUNC) != t["runc_sha"] or sha_file(WORK + "/.bench/svc") != t["svc_sha"] or sha_file(BUILD) != t["build_sha"]:
    fail("runc, the service program or bin/build was changed")
if not is_go_binary(RUNNER) or b"bench37420728/runner" not in open(RUNNER, "rb").read():
    fail("bin/runner is not a Go program of the module bench37420728/runner (build it with bin/build)")
if sha_file(RUNNER) == t["runner_sha"]:
    fail("bin/runner is still the program of the question (src/main.go changed? run bin/build)")

try:
    # run 1: starts the container, stays alive HOLD seconds; has to return from the start within RETURN_WITHIN seconds, with no runc zombie or runc left while it holds
    na = os.urandom(4).hex()
    ida = "b37420728-a" + na
    ids.append(ida)
    ba = make_bundle("oa", na)
    oa = WORK + "/oa.out"
    t0 = time.time()
    p = start_runner(RUNNER, ba, ida, HOLD, oa)
    got = wait_for(lambda: first_line(oa), RETURN_WITHIN, 0.1)
    if got is None:
        st = state(ida) or {}
        finish(p)
        fail("run 1: the program did not return from starting the container in %d s (it printed nothing; the container is %s and answers: %s)" % (RETURN_WITHIN, st.get("status", "not started"), ping(ba)))
    if not got.strip().isdigit() or int(got) > RETURN_WITHIN * 1000 or time.time() - t0 > RETURN_WITHIN + 1:
        finish(p)
        fail("run 1: the first line of the program is not the duration of the start in ms (below %d s): %r" % (RETURN_WITHIN, got))
    kids = children(p.pid)
    if kids:
        finish(p)
        fail("run 1: the program has processes of its own while it holds (zombie or runc left): %s" % kids)
    if p.poll() is not None:
        fail("run 1: the program ended before its hold of %d s (exit %s)" % (HOLD, p.returncode))
    try:
        p.wait(timeout=HOLD + RETURN_WITHIN)
    except subprocess.TimeoutExpired:
        finish(p)
        fail("run 1: the program does not end after its hold")
    if p.returncode != 0:
        fail("run 1: the program exits with status %d after a start that worked: %s" % (p.returncode, short(read(oa))))
    container_runs(ba, ida, na, "run 1 (after the program exited)")
    if runc_processes():
        fail("run 1: a runc process is left: %s" % runc_processes())

    # run 2: no hold: the program ends by itself at once; a second container next to the first
    nb = os.urandom(4).hex()
    idb = "b37420728-b" + nb
    ids.append(idb)
    bb = make_bundle("ob", nb)
    ob = WORK + "/ob.out"
    t0 = time.time()
    p = start_runner(RUNNER, bb, idb, 0, ob)
    try:
        p.wait(timeout=RETURN_WITHIN)
    except subprocess.TimeoutExpired:
        finish(p)
        fail("run 2: the program did not end in %d s" % RETURN_WITHIN)
    if p.returncode != 0:
        fail("run 2: exit status %d: %s" % (p.returncode, short(read(ob))))
    container_runs(bb, idb, nb, "run 2 (after the program exited)")
    container_runs(ba, ida, na, "run 1 (container still running)")
    if runc_processes():
        fail("run 2: a runc process is left: %s" % runc_processes())

    # run 3: runc cannot start the container: the program says why and exits with a status
    idc = "b37420728-c" + os.urandom(4).hex()
    ids.append(idc)
    bc = make_bundle("oc", "x", args=["/nonexistent"])
    oc = WORK + "/oc.out"
    p = start_runner(RUNNER, bc, idc, 0, oc)
    try:
        p.wait(timeout=RETURN_WITHIN)
    except subprocess.TimeoutExpired:
        finish(p)
        fail("run 3: the program did not end in %d s for a container that cannot start" % RETURN_WITHIN)
    msg = read(oc) or ""
    if p.returncode == 0:
        fail("run 3: exit status 0 for a container that cannot start (output: %s)" % short(msg))
    if "no such file or directory" not in msg:
        fail("run 3: the program does not print what runc says (the output has: %s)" % short(msg or "nothing"))
    if state(idc) is not None or runc_processes():
        fail("run 3: the failed container or a runc process is left")
finally:
    for i in ids:
        drop(i)
print("[oracle] PASS: the program returned %s ms after starting the container, held %d s with no child, ended with 0; the container ran on afterwards (answers its nonce, service.log growing) and no runc was left; a second run did the same without holding; a container that cannot start was reported with runc's message and status %d" % (got.strip(), HOLD, p.returncode))
PYEOF
) || { echo "$OUT"; exit 1; }
echo "$OUT"
