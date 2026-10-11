"""verify.py WORK K8S_NAMESPACE POD CONTAINER : run the solution's script for that container and compare what it writes with the lab's record.

It runs `bash WORK/inspect-node.sh K8S_NAMESPACE POD CONTAINER OUTDIR` (OUTDIR is a fresh directory that does not exist yet) and checks, in this
order: the exit status, containers.txt (the IDs of all containers of the node), images.txt (all its images as repository:tag), token.txt (the token
file of the container read from inside it) and uid.txt (the user ID that reading ran under). Prints one short line for the first thing that is wrong
(variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import shutil
import subprocess
import sys

work, ns, pod, name = sys.argv[1:5]
truth = json.load(open(os.path.join(work, ".bench", "truth.json")))
want = [(cid, c) for cid, c in truth["containers"].items() if (c["ns"], c["pod"], c["name"]) == (ns, pod, name)]
assert len(want) == 1, "the lab has no such container"
tid, target = want[0]
out = os.path.join(work, "out-%s-%s-%s" % (ns, pod, name))
shutil.rmtree(out, ignore_errors=True)


def fail(msg):
    print("  -> FAIL: %s/%s/%s: %s" % (ns, pod, name, msg))
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "inspect-node.sh"), ns, pod, name, out], cwd=work, capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 120 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))


def lines(fname):
    p = os.path.join(out, fname)
    if not os.path.isfile(p):
        fail("%s was not written" % fname)
    return [x.strip() for x in open(p, errors="replace").read().splitlines() if x.strip()]


def compare(fname, got, exp, what, hint):
    if len(got) != len(set(got)):
        fail("%s lists %d entries twice" % (fname, len(got) - len(set(got))))
    if not got:
        fail("%s is empty (the node has %d %s)" % (fname, len(exp), what))
    missing, extra = sorted(set(exp) - set(got)), sorted(set(got) - set(exp))
    if missing:
        fail("%s lacks %d of the %d %s %s: %s" % (fname, len(missing), len(exp), what, hint[0], ", ".join(m[:19] for m in missing[:3])))
    if extra:
        fail("%s has %d entries that are not %s %s: %s" % (fname, len(extra), what, hint[1], ", ".join(e[:40] for e in extra[:3])))


compare("containers.txt", lines("containers.txt"), list(truth["containers"]), "containers", ("(an exited one is a container too)", "of the node"))
compare("images.txt", lines("images.txt"), truth["images"], "images", ("(images no container uses are images too)", "as repository:tag"))
tok = open(os.path.join(out, "token.txt"), "rb").read().strip() if os.path.isfile(os.path.join(out, "token.txt")) else None
if tok is None:
    fail("token.txt was not written")
if tok != target["token"].strip().encode():
    other = [c for c in truth["containers"].values() if c["token"].strip().encode() == tok]
    fail("token.txt is not the token of this container" + (" (it is the one of %s/%s/%s)" % (other[0]["ns"], other[0]["pod"], other[0]["name"]) if other else ""))
uid = lines("uid.txt")
if uid != [str(target["uid"])]:
    fail("uid.txt says %s, but the container runs as user %d and the token was read under that user" % (uid[:2] or "nothing", target["uid"]))
print("  -> OK: %s/%s/%s: %d containers, %d images, its token read as user %d" % (ns, pod, name, len(truth["containers"]), len(truth["images"]), target["uid"]))
