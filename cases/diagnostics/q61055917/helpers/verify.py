"""verify.py WORK first|second : run the solution's script, make sure it only read and only asked the node's own containerd, and compare what it wrote with
the lab's record.

It runs `bash WORK/list-node.sh OUTPUT_FILE` (a new path), then `lab.py check` (the node must be as the lab left it: no image, content, container, label or task
changed) and looks at the log of the other socket (WORK/.bench/tap.log, which stays empty unless something connects to it). It reads the JSON object the script
wrote, {"containers": [{id, image, digest, pid}], "images": [{ref, digest}]}, and compares it with the record (WORK/.bench/truth.json, as lab.py keeps it): the
same containers; then, for all of them, the image, the digest of the image and the PID of the task (null without a task); then the same images with the same
digests. Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys

work, phase = sys.argv[1:3]
bench = os.path.join(work, ".bench")
truth = json.load(open(os.path.join(bench, "truth.json")))
SOCK = "/run/bench61055917/containerd/containerd.sock"
out = os.path.join(work, "out-%s.json" % phase)
if os.path.exists(out):
    os.unlink(out)


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "list-node.sh"), out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
c = subprocess.run([sys.executable, os.path.join(bench, "lab.py"), "check", SOCK, work], capture_output=True, text=True)
if c.returncode != 0:
    fail((c.stdout.strip() or c.stderr.strip())[-300:])
touched = [x for x in open(os.path.join(bench, "tap.log")).read().splitlines() if x.strip()]
if touched:
    fail("the script connected to the socket of the other containerd (%d connections)" % len(touched))
if not os.path.isfile(out):
    fail("the script wrote no output file")
try:
    data = json.load(open(out))
except ValueError as e:
    fail("the output is not JSON: %s" % str(e)[:100])
if not isinstance(data, dict) or not all(isinstance(data.get(k), list) and all(isinstance(x, dict) for x in data[k]) for k in ("containers", "images")):
    fail("the output is not an object with the arrays containers and images of objects")
want = truth["containers"]
got = {}
for o in data["containers"]:
    miss = [k for k in ("id", "image", "digest", "pid") if k not in o]
    if miss:
        fail("a container object has no key %s (it has: %s)" % (miss[0], " ".join(sorted(o))[:100]))
    if o["id"] in got:
        fail("the container %s is listed twice" % str(o["id"])[:12])
    got[o["id"]] = o
missing = sorted(set(want) - set(got))
if missing:
    fail("%d of the %d containers are missing, for example %s" % (len(missing), len(want), missing[0][:12]))
extra = sorted(set(got) - set(want))
if extra:
    fail("%d objects are not containers of the node, for example %s" % (len(extra), str(extra[0])[:12]))
order = sorted(want)
for cid in order:
    if got[cid]["image"] != want[cid]["image"]:
        fail("the image of %s is %s, not %s" % (cid[:12], got[cid]["image"], want[cid]["image"]))
for cid in order:
    if got[cid]["digest"] != want[cid]["digest"]:
        fail("the digest of the image of %s (%s) is %s, not %s" % (cid[:12], want[cid]["image"], str(got[cid]["digest"])[:19], want[cid]["digest"][:19]))
for cid in order:
    if got[cid]["pid"] != want[cid]["pid"]:
        what = "has no task, its pid must be null" if want[cid]["pid"] is None else "runs with the pid %s" % want[cid]["pid"]
        fail("%s %s; the pid reported is %s" % (cid[:12], what, got[cid]["pid"]))
imgs = {}
for o in data["images"]:
    if "ref" not in o or "digest" not in o:
        fail("an image object has no key ref or digest (it has: %s)" % " ".join(sorted(o))[:100])
    if not str(o["ref"]).startswith("sha256:"):         # the aliases the CRI plugin adds in k8s.io may be listed or left out
        imgs[o["ref"]] = o["digest"]
lost = sorted(set(truth["images"]) - set(imgs))
if lost:
    fail("%d of the %d images of the node are missing, for example %s" % (len(lost), len(truth["images"]), lost[0]))
more = sorted(set(imgs) - set(truth["images"]))
if more:
    fail("%d listed images are not in the node, for example %s" % (len(more), more[0]))
for ref in sorted(imgs):
    if imgs[ref] != truth["images"][ref]:
        fail("the digest of the image %s is %s, not %s" % (ref, imgs[ref], truth["images"][ref]))
print("  -> OK: %d containers (%d with a task) and %d images, with their digests and PIDs" % (
    len(want), sum(1 for v in want.values() if v["pid"]), len(truth["images"])))
