#!/bin/bash
set -e

CASE_ID="bench54303822"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the saved file is the OCI runtime spec of the running container bench-api, byte for byte the config.json of its bundle, and its values are the container's own..."
OUT=$(sudo python3 - <<'PYEOF' 2>&1
import hashlib
import json
import os
import subprocess
import sys

CASE = "bench54303822"
RUN, LIB = "/run/" + CASE, "/var/lib/" + CASE
STATE = "/tmp/%s/.bench" % CASE
TARGET = "/tmp/%s/config.json" % CASE
rec = json.load(open(STATE + "/lab.json"))
api, batch = rec["containers"]["bench-api"], rec["containers"]["bench-batch"]


def fail(msg):
    print("[verify] FAIL: " + msg)
    sys.exit(1)


def start(pid):
    try:
        return open("/proc/%s/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except OSError:
        return None


# 1. the lab is the one setup made: nothing was stopped, restarted or recreated to get the file
for name, d in rec["daemons"].items():
    if start(d["pid"]) != d["start"]:
        fail("%s was restarted or replaced (it is not the process setup started)" % name)
for name, c in rec["containers"].items():
    j = json.loads(subprocess.run([LIB + "/bin/docker", "inspect", name], capture_output=True, text=True).stdout or "[{}]")[0]
    if j.get("Id") != c["id"] or not j.get("State", {}).get("Running") or str(j["State"]["Pid"]) != c["pid"] or start(c["pid"]) != c["start"]:
        fail("the container %s is not the one setup started (stopped, restarted or recreated)" % name)

# 2. the file
if not os.path.lexists(TARGET):
    fail("%s does not exist" % TARGET)
if os.path.islink(TARGET) or not os.path.isfile(TARGET):
    fail("%s must be a regular file (a copy), not a link" % TARGET)
raw = open(TARGET, "rb").read()
try:
    spec = json.loads(raw)
except ValueError:
    fail("%s is not JSON" % TARGET)
if not isinstance(spec, dict) or "ociVersion" not in spec or "process" not in spec or "linux" not in spec:
    fail("the file is not an OCI runtime spec (no ociVersion / process / linux): it looks like %s" % ("Docker's inspect output" if "Id" in str(spec)[:2000] or isinstance(spec, list) else "something else"))

env = spec["process"].get("env", [])
if spec.get("hostname") == "runc" or not any(e.startswith("BENCH_TOKEN=") for e in env):
    fail("the spec is a template (runc spec) or not the spec of a container of this lab: hostname %r, no BENCH_TOKEN in process.env" % spec.get("hostname"))
if "BENCH_TOKEN=" + batch["token"] in env:
    fail("the spec is the one of the container bench-batch, not of bench-api")
if "BENCH_TOKEN=" + api["token"] not in env:
    fail("process.env of the spec has another BENCH_TOKEN than the one of bench-api")

# 3. the values are the container's own: Docker's object, the real process, the cgroup
if spec.get("hostname") != api["hostname"]:
    fail("hostname %r is not the container's %r" % (spec.get("hostname"), api["hostname"]))
if spec["process"].get("args") != ["/app"]:
    fail("process.args is %r, the container runs /app" % spec["process"].get("args"))
mounts = [m for m in spec.get("mounts", []) if m.get("destination") == "/data"]
if len(mounts) != 1 or mounts[0].get("source") != LIB + "/data-api" or not ({"ro", "rro"} & set(mounts[0].get("options", []))):
    fail("the spec has no read-only bind mount of %s/data-api on /data (mounts: %s)" % (LIB, mounts))
res = spec["linux"].get("resources", {})
if res.get("memory", {}).get("limit") != api["memory"]:
    fail("linux.resources.memory.limit is %r, Docker's is %r" % (res.get("memory", {}).get("limit"), api["memory"]))
cpu = res.get("cpu", {})
if (cpu.get("quota"), cpu.get("period")) != (50000, 100000):
    fail("linux.resources.cpu is %r, the container has 0.5 CPU (quota 50000 per 100000)" % cpu)
pid = api["pid"]
environ = open("/proc/%s/environ" % pid, "rb").read().split(b"\0")
if ("BENCH_TOKEN=" + api["token"]).encode() not in environ:
    fail("the running process of bench-api does not have the token (the lab is broken)")
cg = open("/proc/%s/cgroup" % pid).read().splitlines()
if api["id"] not in spec["linux"].get("cgroupsPath", "") or not any(api["id"] in ln for ln in cg):
    fail("linux.cgroupsPath %r does not name the cgroup of the running process (%s)" % (spec["linux"].get("cgroupsPath"), cg[-1]))
limit = None
for ln in cg:
    h, ctrls, path = ln.split(":", 2)
    for f in ("/sys/fs/cgroup/memory%s/memory.limit_in_bytes" % path if "memory" in ctrls.split(",") else None,
              "/sys/fs/cgroup%s/memory.max" % path if h == "0" and ctrls == "" else None):
        if f and os.path.exists(f):
            limit = int(open(f).read().strip())
if limit != api["memory"]:
    fail("the cgroup of the running process has the memory limit %s, the spec says %s" % (limit, api["memory"]))

# 4. the copy is the bundle's file
found = [os.path.join(dp, "config.json") for dp, dn, fn in os.walk(RUN + "/ctd") if "config.json" in fn and os.path.basename(dp) == api["id"]]
if len(found) != 1:
    fail("the lab has no single bundle for bench-api (%s)" % found)
if hashlib.sha256(raw).digest() != hashlib.sha256(open(found[0], "rb").read()).digest():
    fail("the file differs from the config.json that runc was started with (it was edited or built by hand): keep the file as it is")
print("[verify] %s is a copy of %s: hostname %s, BENCH_TOKEN of bench-api, /data read-only from %s/data-api, memory %d, cpu quota 50000/100000, cgroup %s"
      % (TARGET, found[0].replace(RUN, "<run>"), spec["hostname"], LIB, api["memory"], spec["linux"]["cgroupsPath"]))
print("[verify] ok")
PYEOF
) && RC=0 || RC=$?
echo "$OUT" | tail -8
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: the saved file is the real runc config.json of the running container bench-api."
