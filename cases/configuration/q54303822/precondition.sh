#!/bin/bash
set -e

CASE_ID="bench54303822"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
TARGET_FILE="$WORK_DIR/config.json"

fail() { echo "  -> FAIL: $*"; exit 1; }

sudo python3 - "$STATE_DIR" "$RUN_BASE" "$LIB_BASE" "$TARGET_FILE" <<'PYEOF' || exit 1
import json
import os
import subprocess
import sys

state, run, lib, target = sys.argv[1:5]
rec = json.load(open(state + "/lab.json"))


def fail(msg):
    print("  -> FAIL: " + msg)
    sys.exit(1)


def start(pid):
    try:
        return open("/proc/%s/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except OSError:
        return None


print("[precondition] the lab is as its record says: dockerd and containerd are the processes setup started, both containers run with the same init processes...")
for name, d in rec["daemons"].items():
    if start(d["pid"]) != d["start"]:
        fail("%s is not the process setup started" % name)
for name, c in rec["containers"].items():
    j = json.loads(subprocess.run([lib + "/bin/docker", "inspect", name], capture_output=True, text=True).stdout or "[{}]")[0]
    if j.get("Id") != c["id"] or not j.get("State", {}).get("Running") or str(j["State"]["Pid"]) != c["pid"] or start(c["pid"]) != c["start"]:
        fail("the container %s is not the one setup started" % name)
print("  -> OK")

print("[precondition] the file of the task does not exist yet...")
if os.path.lexists(target):
    fail("%s exists already" % target)
print("  -> OK")

api = rec["containers"]["bench-api"]
cid = api["id"]
print("[precondition] the places named in the question hold no config.json for the container on this engine...")
for p in ("/run/docker/libcontainerd/%s", "/var/run/docker/libcontainerd/%s", "/var/run/docker/containerd/daemon/io.containerd.runtime.v1.linux/moby/%s",
          "/run/containerd/io.containerd.runtime.v1.linux/moby/%s", run + "/exec/containerd/daemon/io.containerd.runtime.v1.linux/moby/%s"):
    if os.path.exists((p % cid) + "/config.json"):
        fail("%s has a config.json" % (p % cid))
st = run + "/exec/runtime-runc/moby/" + cid
if not os.path.isdir(st) or os.path.exists(st + "/config.json"):
    fail("Docker's exec-root state directory of the container is missing or holds a config.json: " + st)
print("  -> OK (Docker's own state directory %s has only runc's state: %s)" % (st, ", ".join(sorted(os.listdir(st)))))

print("[precondition] docker inspect gives Docker's object, not an OCI runtime spec...")
j = json.loads(subprocess.run([lib + "/bin/docker", "inspect", "bench-api"], capture_output=True, text=True).stdout)[0]
if "ociVersion" in j or "process" in j:
    fail("docker inspect looks like an OCI spec")
print("  -> OK")

print("[precondition] control: the container's real bundle exists in containerd's state directory and is an OCI spec of this container...")
found = [os.path.join(dp, "config.json") for dp, dn, fn in os.walk(run + "/ctd") if "config.json" in fn and os.path.basename(dp) == cid]
if len(found) != 1:
    fail("expected one config.json for the container below %s/ctd, found %s" % (run, found))
spec = json.load(open(found[0]))
if "ociVersion" not in spec or ("BENCH_TOKEN=" + api["token"]) not in spec["process"]["env"] or spec["hostname"] != "api-host":
    fail("the bundle's config.json is not the spec of the container")
if spec["linux"]["resources"]["memory"]["limit"] != api["memory"]:
    fail("the memory limit of the bundle differs from Docker's")
print("  -> OK")
print("[precondition] PASS - the container runs, the paths of the question do not exist here, and its real config.json is in the bundle of containerd (to be found).")
PYEOF
