"""verify.py WORK first|second : run the solution's script, make sure it only read, and compare what it wrote with the lab's record.

It runs `bash WORK/find-runtime.sh OUTPUT_FILE` (a new path), then `lab.py check` (the node must be as the lab left it: no container started, stopped, restarted or removed,
no image loaded or removed), and reads the JSON object the script wrote: {"runc_root", "containers": [{id, pid, status}], "containerd_socket", "containerd_namespace",
"images": [{ref, digest}], "runc_has_images"}. It compares it with the record (WORK/.bench/truth.json, as lab.py keeps it): runc has no notion of an image (the flag must be
false); the runtime root; the containers of that root (the same IDs, running, with the PIDs of their processes); the containerd socket and namespace; the images of that
containerd namespace with their digests. Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0
when all is right."""
import json
import os
import subprocess
import sys

work, phase = sys.argv[1:3]
bench = os.path.join(work, ".bench")
truth = json.load(open(os.path.join(bench, "truth.json")))
rand = open(os.path.join(bench, "rand")).read().strip()
RUN = "/run/bench57009928"
DSOCK, CSOCK, EXEC = RUN + "/docker.sock", truth["socket"], os.path.dirname(os.path.dirname(truth["root"]))
out = os.path.join(work, "out-%s.json" % phase)
if os.path.exists(out):
    os.unlink(out)


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "find-runtime.sh"), out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
c = subprocess.run([sys.executable, os.path.join(bench, "lab.py"), "check", DSOCK, CSOCK, EXEC, work], capture_output=True, text=True)
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
miss = [k for k in ("runc_root", "containers", "containerd_socket", "containerd_namespace", "images", "runc_has_images") if k not in data]
if miss:
    fail("the output has no key %s (it has: %s)" % (miss[0], " ".join(sorted(data))[:100]))
if data["runc_has_images"] is not False:
    fail("the output says that runc has images (runc has no notion of an image: it works on bundles; the images are containerd's)")
if not isinstance(data["containers"], list) or not all(isinstance(x, dict) for x in data["containers"]):
    fail("containers is not an array of objects")
if not isinstance(data["images"], list) or not all(isinstance(x, dict) for x in data["images"]):
    fail("images is not an array of objects")
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
    fail("%d of the %d containers of the runtime root are missing, for example %s" % (len(lost), len(want), lost[0][:12]))
more = sorted(set(got) - set(want))
if more:
    fail("%d listed containers are not in the runtime root, for example %s" % (len(more), str(more[0])[:12]))
for cid in sorted(want):
    if got[cid]["status"] != "running":
        fail("the status of %s is %s, not running" % (want[cid]["name"], got[cid]["status"]))
for cid in sorted(want):
    if got[cid]["pid"] != want[cid]["pid"]:
        fail("the pid of %s is %s; the script says %s" % (want[cid]["name"], want[cid]["pid"], got[cid]["pid"]))
if data["containerd_socket"] != truth["socket"]:
    fail("the containerd socket of Docker is %s; the script says %s" % (truth["socket"], data["containerd_socket"]))
if data["containerd_namespace"] != truth["namespace"]:
    fail("the containerd namespace of Docker is %s; the script says %s" % (truth["namespace"], data["containerd_namespace"]))
imgs = {}
for o in data["images"]:
    if "ref" not in o or "digest" not in o:
        fail("an image object has no key ref or digest (it has: %s)" % " ".join(sorted(o))[:100])
    imgs[o["ref"]] = o["digest"]
lost = sorted(set(truth["images"]) - set(imgs))
if lost:
    fail("%d of the %d images of the namespace %s are missing, for example %s" % (len(lost), len(truth["images"]), truth["namespace"], lost[0]))
more = sorted(set(imgs) - set(truth["images"]))
if more:
    fail("%d listed images are not in the namespace %s, for example %s" % (len(more), truth["namespace"], str(more[0])[:80]))
for ref in sorted(imgs):
    if imgs[ref] != truth["images"][ref]:
        fail("the digest of the image %s is %s; the script says %s" % (ref, truth["images"][ref][:19], str(imgs[ref])[:19]))
print("  -> OK: runtime root %s (the daemon's random name %s), %d containers with their PIDs, %d images in containerd, runc has none" % (
    truth["root"].replace(RUN + "/", ""), rand, len(want), len(truth["images"])))
