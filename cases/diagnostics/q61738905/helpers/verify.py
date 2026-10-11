"""verify.py WORK first|second : run the solution's script, make sure it only read, and compare what it wrote with Docker's own record.

It runs `bash WORK/find-runc-root.sh OUTPUT_FILE` (a new path), then `lab.py check` (the node must be as the lab left it: no container started, stopped, restarted, paused or
removed), and reads the JSON object the script wrote: {"runc_root", "containers": [{id, pid, status}]}. It compares it with the record (WORK/.bench/truth.json, as lab.py keeps it:
the full IDs `docker run` printed and the PIDs Docker says): the runtime root; the containers of that root (the same full IDs, running, with the PIDs of their processes).
Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys

work, phase = sys.argv[1:3]
bench = os.path.join(work, ".bench")
truth = json.load(open(os.path.join(bench, "truth.json")))
rand = open(os.path.join(bench, "rand")).read().strip()
DSOCK = "/run/bench61738905/docker.sock"
out = os.path.join(work, "out-%s.json" % phase)
if os.path.exists(out):
    os.unlink(out)


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "find-runc-root.sh"), out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
c = subprocess.run([sys.executable, os.path.join(bench, "lab.py"), "check", DSOCK, work], capture_output=True, text=True)
if c.returncode != 0:
    fail((c.stdout.strip() or c.stderr.strip())[-300:])
if not os.path.isfile(out):
    fail("the script wrote no output file")
try:
    data = json.load(open(out))
except ValueError as e:
    fail("the output is not JSON: %s" % str(e)[:100])
if not isinstance(data, dict):
    fail("the output is not a JSON object")
miss = [k for k in ("runc_root", "containers") if k not in data]
if miss:
    fail("the output has no key %s (it has: %s)" % (miss[0], " ".join(sorted(data))[:100]))
if not isinstance(data["containers"], list) or not all(isinstance(x, dict) for x in data["containers"]):
    fail("containers is not an array of objects")
if str(data["runc_root"]).rstrip("/") != truth["root"]:
    fail("the runtime root of Docker's containers is %s; the script says %s" % (truth["root"], data["runc_root"]))
want = truth["containers"]
got = {}
for o in data["containers"]:
    miss = [k for k in ("id", "pid", "status") if k not in o]
    if miss:
        fail("a container object has no key %s (it has: %s)" % (miss[0], " ".join(sorted(o))[:100]))
    got[o["id"]] = o
lost = sorted(set(want) - set(got))
if lost:
    short = any(0 < len(g) < 64 and any(w.startswith(g) for w in want) for g in got)
    fail("%d of the %d containers of the runtime root are missing%s, for example %s" % (
        len(lost), len(want), " (the IDs it lists are shorter than the full ID)" if short else "", lost[0][:12]))
more = sorted(set(got) - set(want))
if more:
    fail("%d listed containers are not in the runtime root, for example %s" % (len(more), str(more[0])[:12]))
for cid in sorted(want):
    if got[cid]["status"] != "running":
        fail("the status of %s is %s, not running" % (want[cid]["name"], got[cid]["status"]))
for cid in sorted(want):
    if got[cid]["pid"] != want[cid]["pid"]:
        fail("the pid of %s is %s; the script says %s" % (want[cid]["name"], want[cid]["pid"], got[cid]["pid"]))
print("  -> OK: runtime root %s (the daemon's random name %s), %d containers with their full IDs and PIDs" % (
    truth["root"].replace("/run/bench61738905/", ""), rand, len(want)))
