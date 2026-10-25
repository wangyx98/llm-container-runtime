#!/bin/bash
# Oracle: nothing is taken from what the solution says. imgclass is run twice: on the node as it is, and after the oracle changed the node (a new image whose tag is then moved to a newer one while a
# container runs the old one; the exited container removed; a tagged idle image replaced under its tag; a tag record removed), with random contents each time. Each report is compared with the oracle's own
# reading of the CRI's JSON (images, ps -a imageRef) AND with what the oracle built (which images are dangling / digest-only / used); the node (image records, content store, containers, Pods, snapshots)
# must be exactly as before each run: nothing removed, pruned, tagged or started.
CASE_ID="bench71901193"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
[ -x "$LIB/imgclass" ] || fail "$LIB/imgclass does not exist or is not executable"

sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import json, os, subprocess, sys

lib, state = sys.argv[1:3]
crictl, ctr, lab = lib + "/bin/crictl", lib + "/bin/ctr", state + "/lab.py"
cs = lib + "/containerd/io.containerd.content.v1.content/blobs/sha256"
snap = lib + "/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
t = json.load(open(state + "/truth.json"))
REF = "bench71901193.local/"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a, timeout=120):
    try:
        r = subprocess.run(a, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    return r.returncode, (r.stdout + r.stderr).strip()


def cj(*a):
    return json.loads(sh(crictl, *a, "-o", "json")[1])


def labcmd(*a):
    rc, o = sh("python3", lab, *a)
    if rc:
        fail("the oracle could not change the node: " + o[-200:])
    return o


def fingerprint():
    return json.dumps([sh(ctr, "-n", "k8s.io", "images", "ls", "-q")[1], sorted((f, os.path.getsize(os.path.join(cs, f))) for f in os.listdir(cs)),
                       sorted((i["id"], sorted(i["repoTags"]), sorted(i["repoDigests"])) for i in cj("images")["images"]), sorted((c["id"], c["state"], c["imageRef"]) for c in cj("ps", "-a")["containers"]), sorted((p["id"], p["state"]) for p in cj("pods")["items"]),
                       sorted(os.listdir(snap))], sort_keys=True)


def reading():
    users = {}
    for c in cj("ps", "-a")["containers"]:
        users.setdefault(c["imageRef"], []).append(c["id"])
    images = []
    for i in sorted(cj("images")["images"], key=lambda i: i["id"]):
        tags, digests = sorted(i["repoTags"]), sorted(i["repoDigests"])
        ids = sorted(users.get(i["id"], []))
        images.append({"id": i["id"], "repo_tags": tags, "repo_digests": digests, "class": "tagged" if tags else ("digest_only" if digests else "dangling"), "container_ids": ids, "in_use": bool(ids)})
    return {"images": images, "dangling_ids": [i["id"] for i in images if i["class"] == "dangling"],
            "removable_ids": [i["id"] for i in images if i["class"] == "dangling" and not i["in_use"]]}


def check(phase, dangling, removable, digest_only, used):
    want = reading()
    # the oracle's own sanity: what it read is what it built
    by = {i["id"]: i for i in want["images"]}
    if sorted(want["dangling_ids"]) != sorted(dangling) or sorted(want["removable_ids"]) != sorted(removable) \
            or sorted(i for i in by if by[i]["class"] == "digest_only") != sorted(digest_only) or sorted(i for i in by if by[i]["in_use"]) != sorted(used):
        fail("the node does not hold the images and containers that were built (phase %s)%s" % (phase, ": the solution changed the node before the tool was run" if phase == "A" else ": oracle inconsistency"))
    before = fingerprint()
    rc, out = sh("sudo", lib + "/imgclass", timeout=45)
    if rc != 0:
        fail("%s: imgclass exits %d: %s" % (phase, rc, out[-300:]))
    try:
        rep = json.loads(out)
    except ValueError:
        fail("%s: imgclass prints no JSON object: %r" % (phase, out[:200]))
    if fingerprint() != before:
        fail("%s: imgclass changed the node (image records, content, containers, Pods or snapshots)" % phase)
    if not isinstance(rep, dict) or not isinstance(rep.get("images"), list):
        fail("%s: the report has no list 'images'" % phase)
    got = {i.get("id"): i for i in rep["images"] if isinstance(i, dict)}
    if sorted(got) != sorted(by) or len(rep["images"]) != len(by):
        fail("%s: the report lists the images %s, the node has %s" % (phase, sorted(x[:19] for x in got if x), sorted(x[:19] for x in by)))
    for iid, w in by.items():
        g = got[iid]
        for k in ("repo_tags", "repo_digests", "container_ids"):
            if sorted(g.get(k) or []) != w[k] or not isinstance(g.get(k), list):
                fail("%s: image %s: %s is %s, expected %s" % (phase, iid[:19], k, g.get(k), w[k]))
        if g.get("class") != w["class"] or g.get("in_use") is not w["in_use"]:
            fail("%s: image %s (tags %s, digests %d, containers %d) is class %s in_use %s in the report, expected %s / %s" % (
                 phase, iid[:19], w["repo_tags"], len(w["repo_digests"]), len(w["container_ids"]), g.get("class"), g.get("in_use"), w["class"], w["in_use"]))
    if [i.get("id") for i in rep["images"]] != sorted(by):
        fail("%s: 'images' is not sorted by id" % phase)
    for k in ("dangling_ids", "removable_ids"):
        if rep.get(k) != want[k]:
            fail("%s: %s is %s, expected %s" % (phase, k, rep.get(k), want[k]))
    return rep


# phase A: the node as setup left it
check("A", [t["web1"], t["old1"], t["job1"]], [t["job1"]], [t["dig"], t["dig2"]], [t["web1"], t["old1"], t["dig2"]])

# phase B: the oracle changes the node
new1 = labcmd("image", REF + "new:latest", "new1")
c_new = labcmd("run", t["pod"], "newc", REF + "new:latest")
new2 = labcmd("image", REF + "new:latest", "new2")            # the tag moves on: new1 is now untagged and used by a running container
labcmd("rm", t["c_old"])                                        # old1: untagged, now no container
idle2 = labcmd("image", REF + "idle:1", "idle2")                # idle (tagged, idle) loses its tag to a newer image
sh(ctr, "-n", "k8s.io", "images", "rm", REF + "job:latest")     # job2 loses its tag record: only its ID is left
check("B", [t["web1"], t["old1"], t["job1"], t["job2"], t["idle"], new1], [t["old1"], t["job1"], t["job2"], t["idle"]], [t["dig"], t["dig2"]],
      [t["web1"], t["dig2"], new1])
print("imgclass: the report equals the CRI's own reading in two phases (the node as left; after a tag moved under a running container, an exited container removed, a tag replaced, a tag record removed): dangling, digest-only and used images told apart, removable = dangling and unused; the node unchanged by it")
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
