#!/bin/bash
# Postcondition oracle. The workload is run the way a kubelet runs it, through the CRI of the node, and judged on what the JVM and the cache really did:
#   1. the node is still the node: the scripts are as recorded, containerd is the process of the pid file, started from node/containerd.toml on the node's socket;
#      the pod and the container files changed only where they may: the pod's cgroup parent, the container's image (one of the two images of the node, by image id)
#      - the memory limit stays 512 MiB, the environment is the nonce only, there is no command, no arguments, no extra option
#   2. phase A: `cachenodectl restart`, then run-workload with a fresh nonce: exit 0, the cache is initialised (off-heap 50 MB), put and get return the nonce,
#      the JVM's total physical memory equals the container's limit (512 MiB; not 0, not the memory of the host), no JVM option or JAVA_TOOL_OPTIONS in the container
#   3. phase B: `cachenodectl restart` again and a second nonce: the same
# cleanup.sh removes everything afterwards.

CASE_ID="bench68845002"
STATE_DIR="/tmp/$CASE_ID/.bench"

if ! sudo test -d "$STATE_DIR"; then
    echo "[oracle] FAIL: $STATE_DIR is missing: setup.sh has not run"
    exit 1
fi

sudo python3 - <<'PYEOF'
import json
import os
import re
import subprocess
import sys

CASE = "bench68845002"
L = "/var/lib/" + CASE
R = "/run/" + CASE
STATE = "/tmp/%s/.bench" % CASE
SOCK = R + "/containerd.sock"
LIMIT = 536870912
STAGE = "oracle"


def fail(msg):
    print("[%s] FAIL: %s" % (STAGE, msg))
    sys.exit(1)


def sh(cmd, timeout=180, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out: " + " ".join(cmd[:3]))


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def total(out):
    m = re.search(r"^probe java=(\S+) total=(\d+)", out, re.M)
    return (m.group(1), int(m.group(2))) if m else (None, None)


def line(out, key):
    m = re.search(r"^probe %s=(.*)$" % key, out, re.M)
    return m.group(1) if m else None


# ---- 1. the node, the pod, the container
chk = sh(["sha256sum", "-c", "--quiet", STATE + "/files.sha"], 30, cwd=L)
if chk.returncode != 0:
    fail("a script of the node was changed (cachenodectl and run-workload must stay as they are): " + (chk.stdout + chk.stderr).strip()[:200])
try:
    pod = json.load(open(L + "/workload/pod.json"))
    cont = json.load(open(L + "/workload/container.json"))
    pod0 = json.load(open(STATE + "/pod.orig"))
    cont0 = json.load(open(STATE + "/container.orig"))
except ValueError as e:
    fail("a workload file is not valid JSON: %s" % e)
for d in (pod, pod0):
    d.get("linux", {}).pop("cgroup_parent", None)
if pod != pod0:
    fail("pod.json changed in something else than the cgroup parent of the pod")
ids = {l.split()[1] for l in (read(STATE + "/images.id") or "").splitlines()}
ref = cont.get("image", {}).get("image", "")
c1 = dict(cont)
c1.pop("image", None)
c0 = dict(cont0)
c0.pop("image", None)
if c1 != c0:
    fail("container.json changed in something else than the image: the memory limit (%d), the environment (the nonce only), the command and the arguments must stay" % LIMIT)

# ---- 2. and 3. the node restarted, the workload run with a fresh nonce, twice
def phase(tag, nonce):
    r = sh([L + "/bin/cachenodectl", "restart"], 120)
    if r.returncode != 0:
        fail("%s: cachenodectl restart failed: %s" % (tag, (r.stdout + r.stderr).strip()[-300:]))
    pid = (read(R + "/containerd.pid") or "").strip()
    cmd = (read("/proc/%s/cmdline" % pid) or "").replace("\0", " ") if pid.isdigit() else ""
    if "containerd --config %s/node/containerd.toml --address %s" % (L, SOCK) not in cmd:
        fail("%s: the node's containerd is not the process started by cachenodectl from the node's configuration: %r" % (tag, cmd))
    r = sh(["crictl", "--config", L + "/node/crictl.yaml", "inspecti", "-o", "go-template", "--template", "{{.status.id}}", ref])
    if r.stdout.strip() not in ids:
        fail("%s: the image %r of the container is not one of the two images of the node (by id)" % (tag, ref))
    r = sh([L + "/bin/run-workload", nonce], 240)
    out = r.stdout + r.stderr
    java, mem = total(out)
    if r.returncode != 0 or "cache-ok nonce=%s" % nonce not in out:
        fail("%s: the workload failed (exit %d): %s" % (tag, r.returncode, "\n".join(l for l in out.splitlines() if l.startswith(("cache-", "workload", "probe java")))[-500:]))
    if mem != LIMIT or line(out, "limit") != str(LIMIT):
        fail("%s: the JVM's total physical memory is %s, the container's limit is %s: it must be the limit (%d), not 0 and not the memory of the host" % (tag, mem, line(out, "limit"), LIMIT))
    if line(out, "jvm-args") is None or not re.search(r"^probe jvm-args=\[\] JAVA_TOOL_OPTIONS=null JDK_JAVA_OPTIONS=null _JAVA_OPTIONS=null$", out, re.M):
        fail("%s: the JVM runs with options or option variables of the environment: %s" % (tag, line(out, "jvm-args")))
    print("  %s: java %s, the cache starts (off-heap 50 MB), put/get return the nonce %s; the JVM's total=%d equals the limit; cgroup %s"
          % (tag, java, nonce, mem, (line(out, "cgroup-memory") or "").split(":", 2)[-1][-70:]))


import secrets
phase("phase A", "a-" + secrets.token_hex(5))
phase("phase B after another restart", "b-" + secrets.token_hex(5))
print("[oracle] ALL CHECKS PASSED: the cache starts with the container's own memory limit, as left and after restarts of the node")
PYEOF
