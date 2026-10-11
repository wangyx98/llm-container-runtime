"""verify.py WORK first|second : run the solution's script, make sure it changed nothing, and compare what it wrote with the lab's record.

It runs `bash WORK/inspect.sh OUTPUT_FILE` (a new path), then `lab.py check` (the node must be as the lab left it: the script only reads), and
reads the JSON array it wrote: one object per container of the containerd in every namespace, with the keys namespace, id, image, runtime, labels,
env, mounts, status, pid. They are compared with the record (WORK/.bench/truth.json, as lab.py keeps it): the same containers (the same ID can be in
several namespaces), and then, field by field over all containers: image, runtime, labels (the ones the lab put on: owner, release), env (the
variables the image and the lab gave), mounts (the two bind mounts: destination, source, read-only or not), status (running, stopped or none), pid.
Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys

work, phase = sys.argv[1:3]
bench = os.path.join(work, ".bench")
truth = json.load(open(os.path.join(bench, "truth.json")))
want = {tuple(k.split("|")): v for k, v in truth["containers"].items()}
PREFIX = "bench67990667-"
SOCK = "/run/bench67990667/containerd/containerd.sock"
out = os.path.join(work, "out-%s.json" % phase)
if os.path.exists(out):
    os.unlink(out)


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


def name(k):
    return "%s/%s" % (k[0].replace(PREFIX, ""), k[1])


try:
    r = subprocess.run(["bash", os.path.join(work, "inspect.sh"), out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
c = subprocess.run([sys.executable, os.path.join(bench, "lab.py"), "check", SOCK, work], capture_output=True, text=True)
if c.returncode != 0:
    fail((c.stdout.strip() or c.stderr.strip())[-300:])
if not os.path.isfile(out):
    fail("the script wrote no output file")
try:
    data = json.load(open(out))
except ValueError as e:
    fail("the output is not JSON: %s" % str(e)[:100])
if not isinstance(data, list) or not all(isinstance(x, dict) for x in data):
    fail("the output is not an array of objects")
if not data:
    fail("the output is an empty array (the node has %d containers in %d namespaces)" % (len(want), len(truth["namespaces"])))
KEYS = ["namespace", "id", "image", "runtime", "labels", "env", "mounts", "status", "pid"]
got = {}
for o in data:
    miss = [k for k in KEYS if k not in o]
    if miss:
        fail("an object has no key %s (it has: %s)" % (miss[0], " ".join(sorted(o))[:100]))
    k = (o["namespace"], o["id"])
    if k in got:
        fail("the container %s is listed twice" % name(k))
    got[k] = o
missing = sorted(set(want) - set(got))
if missing:
    spaces = sorted({name(k).split("/")[0] for k in missing})
    fail("%d of the %d containers are missing (namespaces: %s); for example %s" % (len(missing), len(want), ", ".join(spaces), name(missing[0])))
extra = sorted(set(got) - set(want))
if extra:
    fail("%d objects are not containers of the node: %s" % (len(extra), ("%s in %s" % (extra[0][1], extra[0][0]))[:80]))
order = sorted(want)
for k in order:
    if got[k]["image"] != want[k]["image"]:
        fail("the image of %s is %s, not %s" % (name(k), got[k]["image"], want[k]["image"]))
for k in order:
    if got[k]["runtime"] != want[k]["runtime"]:
        fail("the runtime of %s is %s, not %s" % (name(k), got[k]["runtime"], want[k]["runtime"]))
for k in order:
    lab = got[k]["labels"]
    if not isinstance(lab, dict):
        fail("the labels of %s are not an object" % name(k))
    for lk, lv in want[k]["labels"].items():
        if lab.get(lk) != lv:
            fail("the label %s of %s is %s, not %s" % (lk, name(k), lab.get(lk), lv))
for k in order:
    env = got[k]["env"]
    if not isinstance(env, list) or not all(isinstance(e, str) and "=" in e for e in env):
        fail("the env of %s is not an array of KEY=VALUE strings" % name(k))
    lost = [e for e in want[k]["env"] if e not in env]
    if lost:
        fail("the env of %s has no %s (%d of %d variables of the container are missing)" % (name(k), lost[0].split("=")[0], len(lost), len(want[k]["env"])))
for k in order:
    mounts = got[k]["mounts"]
    if not isinstance(mounts, list) or not all(isinstance(m, dict) for m in mounts):
        fail("the mounts of %s are not an array of objects" % name(k))
    for dst, src, ro in want[k]["mounts"]:
        m = [x for x in mounts if x.get("destination") == dst]
        if not m or m[0].get("source") != src:
            fail("the mount %s of %s is %s, not %s" % (dst, name(k), (m[0].get("source") if m else "missing"), src))
        opts = m[0].get("options") or []
        if ("ro" in opts) != ro:
            fail("the mount %s of %s should be %s, its options are: %s" % (dst, name(k), "read-only" if ro else "read-write", " ".join(map(str, opts))))
for k in order:
    if got[k]["status"] != want[k]["status"]:
        fail("the status of %s is %s, not %s" % (name(k), got[k]["status"], want[k]["status"]))
for k in order:
    if got[k]["pid"] != want[k]["pid"]:
        what = "has no task, its pid must be null" if want[k]["status"] == "none" else "is %s with the pid %s" % (want[k]["status"], want[k]["pid"])
        fail("%s %s; the pid reported is %s" % (name(k), what, got[k]["pid"]))
print("  -> OK: %d containers in %d namespaces (%d running, %d stopped, %d without a task)" % (
    len(want), len(truth["namespaces"]), sum(v["status"] == "running" for v in want.values()),
    sum(v["status"] == "stopped" for v in want.values()), sum(v["status"] == "none" for v in want.values())))
