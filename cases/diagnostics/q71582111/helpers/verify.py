"""verify.py WORK : run the solution's script and compare what it writes with the lab's record of the images of the node.

It runs `bash WORK/list-images.sh OUTPUT_FILE` (a new path) and reads the lines it wrote, "NAMESPACE NAME DIGEST", one per image name of the
containerd in every namespace. The lines must be those of the record (WORK/.bench/truth.json, as lab.py keeps it): the same set, no line twice.
Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys

work = sys.argv[1]
truth = json.load(open(os.path.join(work, ".bench", "truth.json")))["images"]
want = {(ns, name): dg for ns, names in truth.items() for name, dg in names.items()}
out = os.path.join(work, "out-images.txt")
if os.path.exists(out):
    os.unlink(out)


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "list-images.sh"), out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
if not os.path.isfile(out):
    fail("the script wrote no output file")
raw = [x for x in open(out, errors="replace").read().splitlines() if x.strip()]
if not raw:
    fail("the output is empty (the node has %d image names in %d namespaces)" % (len(want), len(truth)))
got = {}
for line in raw:
    f = line.split()
    if len(f) != 3 or not f[2].startswith("sha256:"):
        fail("a line is not 'NAMESPACE NAME DIGEST': %s" % line[:100])
    if (f[0], f[1]) in got:
        fail("the name %s of the namespace %s is listed twice" % (f[1], f[0]))
    got[(f[0], f[1])] = f[2]
ids = [k for k in got if k[1].startswith("sha256:")]
if ids:
    fail("%d lines are entries named by an image ID (sha256:...), which are not image names: %s" % (len(ids), " ".join(ids[0])[:90]))
wrong = [k for k in got if k in want and got[k] != want[k]]
if wrong:
    k = wrong[0]
    fail("the digest of %s in the namespace %s is %s, not %s (%d wrong)" % (k[1], k[0], got[k][:19], want[k][:19], len(wrong)))
missing = sorted(set(want) - set(got))
if missing:
    spaces = sorted({k[0] for k in missing})
    fail("%d of the %d image names are missing (namespaces: %s); for example %s in %s" % (len(missing), len(want), ", ".join(spaces), missing[0][1], missing[0][0]))
extra = sorted(set(got) - set(want))
if extra:
    fail("%d lines are not image names of the node: %s %s" % (len(extra), extra[0][0], extra[0][1][:70]))
print("  -> OK: %d image names in %d namespaces, with their digests" % (len(want), len(truth)))
