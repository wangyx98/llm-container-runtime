#!/bin/bash
# Precondition oracle: the node is as setup.sh left it, and the cause of the 0B is told apart from the other suspects by controls that change ONE thing each:
#   - the node: containerd runs as started by cachenodectl (pid file, executable, socket), the scripts and the images are as recorded
#   - the failure: the workload ends with "Attempting to allocate 50.0MB of memory when the host only contains 0B of physical memory"; the JVM's own probe says total=0 while the
#     container's memory limit file says 536870912; the memory cgroup of the container is named <pod parent>.slice:cri-containerd:<id> (a colon in the path)
#   - JDK (same pod, same path, JDK 11.0.13 image): works, total = the limit            -> the JDK version matters
#   - path (same image, a cgroupfs-style pod parent, no .slice, no colon): works         -> the colon in the cgroup path matters
#   - runtime (same image, a private Docker daemon, runc, --memory 512m): works          -> Docker's cgroup path has no colon
#   - the asker's workaround (-XX:-UseContainerSupport): the cache starts, but the JVM sees the memory of the host, not the limit
# Exits non-zero with a message when any of it is not true.

CASE_ID="bench68845002"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[precondition] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

CASE = "bench68845002"
L = "/var/lib/" + CASE
R = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
SOCK = R + "/containerd.sock"
LIMIT = 536870912
STAGE = "precondition"
OLD_REF = CASE + ".local/cache-app:jdk11.0.9"
NEW_REF = CASE + ".local/cache-app:jdk11.0.13"


def fail(msg):
    print("[%s] FAIL: %s" % (STAGE, msg))
    sys.exit(1)


def sh(cmd, timeout=180, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out")


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def workload(nonce, d=None):
    r = sh([L + "/bin/run-workload", nonce] + ([d] if d else []), timeout=240)
    return r.returncode, r.stdout + r.stderr


def probe(out, key):
    m = re.search(r"^probe %s=(.*)$" % key, out, re.M)
    return m.group(1) if m else None


def total(out):
    m = re.search(r"^probe java=\S+ total=(\d+)", out, re.M)
    return int(m.group(1)) if m else None


def variant(change):
    d = tempfile.mkdtemp(prefix="wl-", dir="/tmp/" + CASE)
    shutil.copy(L + "/workload/pod.json", d + "/pod.json")
    shutil.copy(L + "/workload/container.json", d + "/container.json")
    change(d)
    return d


def edit_json(path, fn):
    with open(path) as f:
        data = json.load(f)
    fn(data)
    with open(path, "w") as f:
        json.dump(data, f)


# ---- the node as recorded
pid = (read(R + "/containerd.pid") or "").strip()
if not pid.isdigit() or os.path.basename(os.path.realpath("/proc/%s/exe" % pid)) != "containerd":
    fail("the node's containerd is not running from cachenodectl (pid file %r)" % pid)
if sh(["ctr", "-a", SOCK, "version"], 20).returncode != 0:
    fail("the node's containerd does not answer on " + SOCK)
chk = sh(["sha256sum", "-c", "--quiet", STATE + "/files.sha"], 30, cwd=L)
if chk.returncode != 0:
    fail("a script of the node is not as recorded: " + (chk.stdout + chk.stderr).strip()[:200])
for f, orig in (("workload/pod.json", "pod.orig"), ("workload/container.json", "container.orig"), ("node/containerd.toml", "containerd.orig")):
    if read(L + "/" + f) != read(STATE + "/" + orig):
        fail("%s is not as recorded" % f)
imgs = dict(l.split() for l in (read(STATE + "/images.id") or "").splitlines())
for name, ref in (("OLD", OLD_REF), ("NEW", NEW_REF)):
    r = sh(["crictl", "--config", L + "/node/crictl.yaml", "inspecti", "-o", "go-template", "--template", "{{.status.id}}", ref])
    if r.stdout.strip() != imgs.get(name):
        fail("the image %s is not the recorded one" % ref)
print("  node: containerd (pid %s) serves the CRI on %s; both images and the workload files are as recorded" % (pid, SOCK))

# ---- the failure, as the engineer sees it
rc, out = workload("pre-a")
if rc == 0 or "host only contains 0B of physical memory" not in out:
    fail("the workload does not fail with 'host only contains 0B of physical memory' (exit %d):\n%s" % (rc, out[-600:]))
if total(out) != 0 or probe(out, "limit") != str(LIMIT):
    fail("the JVM's probe is not total=0 with the container's limit file at %d: total=%s limit=%s" % (LIMIT, total(out), probe(out, "limit")))
cg = probe(out, "cgroup-memory") or ""
if not re.search(r"\.slice:cri-containerd:[0-9a-f]{64}$", cg):
    fail("the memory cgroup of the container has no colon in its name: %r" % cg)
print("  failure: exit %d, 'host only contains 0B of physical memory'; the JVM's total=0 while the limit file says %d; cgroup %s" % (rc, LIMIT, cg.split(":", 2)[2][-90:]))

# ---- control JDK: the same pod and path on JDK 11.0.13
d = variant(lambda d: edit_json(d + "/container.json", lambda j: j["image"].update(image=NEW_REF)))
rc, out = workload("pre-b", d)
cg2 = probe(out, "cgroup-memory") or ""
if rc != 0 or "cache-ok nonce=pre-b" not in out or total(out) != LIMIT or ".slice:cri-containerd:" not in cg2:
    fail("control JDK: JDK 11.0.13 with the same colon path should work with total=%d: exit %d total=%s cgroup=%s" % (LIMIT, rc, total(out), cg2))
print("  control JDK 11.0.13, same cgroup path with the colon: cache ok, total=%d" % total(out))

# ---- control path: the same image and JDK 11.0.9, a cgroupfs-style parent (no .slice, no colon)
d = variant(lambda d: edit_json(d + "/pod.json", lambda j: j["linux"].update(cgroup_parent="/kubepods/burstable/pod6bd1d7f1-9a2c-4a0e-8b3f-c4a1e2d3b5a6")))
rc, out = workload("pre-c", d)
cg3 = probe(out, "cgroup-memory") or ""
if rc != 0 or "cache-ok nonce=pre-c" not in out or total(out) != LIMIT or "cri-containerd" in cg3 or cg3.count(":") != 2:
    fail("control path: JDK 11.0.9 with a cgroup path without a colon should work with total=%d: exit %d total=%s cgroup=%s" % (LIMIT, rc, total(out), cg3))
print("  control path, JDK 11.0.9 with a cgroup path without a colon: cache ok, total=%d" % total(out))

# ---- the asker's workaround: the JVM stops looking at the container
d = variant(lambda d: edit_json(d + "/container.json", lambda j: j.update(envs=j["envs"] + [{"key": "JAVA_TOOL_OPTIONS", "value": "-XX:-UseContainerSupport"}])))
rc, out = workload("pre-d", d)
if rc != 0 or "cache-ok nonce=pre-d" not in out or total(out) in (0, LIMIT):
    fail("workaround: -XX:-UseContainerSupport should start the cache but show the memory of the host: exit %d total=%s" % (rc, total(out)))
print("  the asker's workaround -XX:-UseContainerSupport: cache starts, but the JVM sees total=%d (the host), not the limit %d" % (total(out), LIMIT))

# ---- control runtime: the same image on Docker (private daemon, runc, cgroupfs)
for d_ in (L + "/ctl-data", R + "/ctl-exec", L + "/etc"):
    os.makedirs(d_, exist_ok=True)
with open(L + "/etc/ctl.json", "w") as f:
    json.dump({"data-root": L + "/ctl-data", "exec-root": R + "/ctl-exec", "exec-opts": ["native.cgroupdriver=cgroupfs"], "cgroup-parent": "/bench68845002-ctl", "features": {"containerd-snapshotter": False},
               "bridge": "none", "iptables": False, "ip6tables": False, "ip-forward": False}, f)
proc = subprocess.Popen(["dockerd", "--config-file", L + "/etc/ctl.json", "--host", "unix://" + R + "/ctl.sock", "--pidfile", R + "/ctl.pid"],
                        stdout=open(R + "/ctl.log", "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, start_new_session=True)
DK = ["docker", "-H", "unix://" + R + "/ctl.sock"]
try:
    for _ in range(100):
        if sh(DK + ["version"], 5).returncode == 0:
            break
        time.sleep(0.4)
    else:
        fail("the control docker daemon did not come up: " + (read(R + "/ctl.log") or "")[-300:])
    r = sh(DK + ["load", "-i", STATE + "/old.tar"], 120)
    if r.returncode != 0:
        fail("control runtime: docker load failed: " + r.stderr.strip()[:300])
    r = sh(DK + ["run", "--rm", "--network", "none", "-m", "512m", "-e", "NONCE=pre-e", OLD_REF], 120)
    out = r.stdout + r.stderr
    cg4 = probe(out, "cgroup-memory") or ""
    if r.returncode != 0 or "cache-ok nonce=pre-e" not in out or total(out) != LIMIT or ":cri-containerd:" in cg4:
        fail("control runtime: the same image on Docker/runc with 512m should work with total=%d: exit %d total=%s cgroup=%s\n%s" % (LIMIT, r.returncode, total(out), cg4, out[-300:]))
    print("  control runtime, the same image (JDK 11.0.9) on Docker/runc with --memory 512m: cache ok, total=%d, cgroup %s" % (total(out), cg4.split(":", 2)[2][:20] + "..."))
finally:
    for cid in sh(DK + ["ps", "-aq"], 20).stdout.split():
        sh(DK + ["rm", "-f", cid], 60)
    proc.terminate()
    try:
        proc.wait(40)
    except subprocess.TimeoutExpired:
        proc.kill()
    for _ in range(20):
        if not any((L + "/ctl-") in m for m in (read("/proc/mounts") or "").splitlines()):
            break
        time.sleep(0.3)
    shutil.rmtree(L + "/ctl-data", ignore_errors=True)
    shutil.rmtree(R + "/ctl-exec", ignore_errors=True)
print("[precondition] PASS - the 0B is real; the colon in the container's cgroup path read by JDK 11.0.9 is the cause (JDK, path and runtime controls); the workaround hides it")
PYEOF
