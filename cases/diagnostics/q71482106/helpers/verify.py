"""verify.py WORK TAG : run the solution's script and compare the JSON it writes with the lab's record.

It runs `bash WORK/pause-map.sh WORK/out-TAG.json` (the file does not exist yet) and checks, in this order: the exit status, that the file is a JSON
list of objects, that every sandbox_id is a full 64-character ID, that the sandboxes are exactly the pods of the node (nothing missing, nothing
else: a container ID is not a sandbox), each pod's namespace/name, its pause_pid (the process of the sandbox, not any process called pause), its
netns (the net namespace of that process: the number in net:[...]) and then its containers (exactly the ones of that pod: ID, name, pid, and the
net namespace each one is really in, which is the pod's). Prints one short line for the first thing that is wrong (variable-length details last)
and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import re
import shutil
import subprocess
import sys

work, tag = sys.argv[1:3]
truth = json.load(open(os.path.join(work, ".bench", "truth.json")))
out = os.path.join(work, "out-%s.json" % tag)
shutil.rmtree(out, ignore_errors=True)
if os.path.exists(out):
    os.unlink(out)


def fail(msg):
    print("  -> FAIL: %s: %s" % (tag, msg))
    sys.exit(1)


try:
    r = subprocess.run(["bash", os.path.join(work, "pause-map.sh"), out], cwd=work, capture_output=True, text=True, timeout=180)
except subprocess.TimeoutExpired:
    fail("the script did not finish in 180 s")
if r.returncode != 0:
    fail("the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-200:]))
if not os.path.isfile(out):
    fail("the script did not write %s" % out)
try:
    data = json.load(open(out))
except ValueError as e:
    fail("%s is not valid JSON (%s)" % (out, str(e)[:80]))
if not isinstance(data, list) or not all(isinstance(x, dict) for x in data):
    fail("the JSON is not a list with one object per pod sandbox")


def num(v):
    """an integer, or the text of one, or net:[N]"""
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        m = re.fullmatch(r"(?:net:\[)?([0-9]+)\]?", v.strip())
        return int(m.group(1)) if m else None
    return None


HEX = re.compile(r"^[0-9a-f]{64}$")
ids = [str(x.get("sandbox_id", "")) for x in data]
bad = [i for i in ids if not HEX.match(i)]
if bad:
    fail("%d sandbox_id(s) are not a full 64-character ID: %s" % (len(bad), ", ".join(b[:20] for b in bad[:3]) or "(none given)"))
if len(ids) != len(set(ids)):
    fail("a sandbox is listed twice")
missing, extra = sorted(set(truth["sandboxes"]) - set(ids)), sorted(set(ids) - set(truth["sandboxes"]))
if missing:
    fail("%d of the %d pods are missing (%s)" % (len(missing), len(truth["sandboxes"]), ", ".join(truth["sandboxes"][m]["pod"] for m in missing)))
if extra:
    other = {c: v for c, v in truth["containers"].items() if c in extra}
    fail("%d sandbox_id(s) are not pod sandboxes%s: %s" % (len(extra), " (container IDs)" if other else "", ", ".join(e[:12] for e in extra[:3])))

by_id = {x["sandbox_id"]: x for x in data}
for sid, s in truth["sandboxes"].items():
    x = by_id[sid]
    if x.get("pod") != s["pod"]:
        fail("the sandbox %s is the pod %s, not %s" % (sid[:12], s["pod"], x.get("pod")))
    pp = num(x.get("pause_pid"))
    if pp is None:
        fail("%s has no pause_pid" % s["pod"])
    if pp != s["pid"]:
        owner = [t["pod"] for t in truth["sandboxes"].values() if t["pid"] == pp]
        mine = [c["name"] for c in truth["containers"].values() if c["pid"] == pp]
        fail("%s: pause_pid %d is not the process of its sandbox%s" % (
            s["pod"], pp, " (it is the sandbox of %s)" % owner[0] if owner else " (it is the container %s)" % mine[0] if mine else ""))
    ns = num(x.get("netns"))
    if ns is None:
        fail("%s has no netns (the number of its net namespace)" % s["pod"])
    if ns != s["netns"]:
        fail("%s: netns %d is not the net namespace of its pause process" % (s["pod"], ns))
    mine = {c: v for c, v in truth["containers"].items() if v["sandbox"] == sid}
    cs = x.get("containers")
    if not isinstance(cs, list) or not all(isinstance(c, dict) for c in cs):
        fail("%s: containers is not a list of objects" % s["pod"])
    cids = [str(c.get("id", "")) for c in cs]
    if len(cids) != len(set(cids)):
        fail("%s: a container is listed twice" % s["pod"])
    lack, more = sorted(set(mine) - set(cids)), sorted(set(cids) - set(mine))
    if lack:
        fail("%s lacks %d of its %d containers: %s" % (s["pod"], len(lack), len(mine), ", ".join(mine[c]["name"] for c in lack)))
    if more:
        foreign = [truth["sandboxes"][truth["containers"][c]["sandbox"]]["pod"] for c in more if c in truth["containers"]]
        fail("%s lists %d container(s) that are not its own%s: %s" % (
            s["pod"], len(more), " (of %s)" % foreign[0] if foreign else "", ", ".join(c[:12] for c in more[:3])))
    for c in cs:
        t = mine[c["id"]]
        if c.get("name") != t["name"]:
            fail("%s: the container %s is called %s, not %s" % (s["pod"], c["id"][:12], t["name"], c.get("name")))
        if num(c.get("pid")) != t["pid"]:
            fail("%s: the pid of the container %s is %s, not %d" % (s["pod"], t["name"], c.get("pid"), t["pid"]))
        if num(c.get("netns")) != t["netns"]:
            fail("%s: the netns of the container %s is %s, not %d" % (s["pod"], t["name"], c.get("netns"), t["netns"]))
print("  -> OK: %d pods, %d containers: every sandbox with its pause pid, its net namespace and its own containers" % (
    len(truth["sandboxes"]), len(truth["containers"])))
