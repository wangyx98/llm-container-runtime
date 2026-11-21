#!/bin/bash
set -e

CASE_ID="bench76134722"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] checking the state setup recorded and the node's containerd..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
sudo ctr -a "$CTD_SOCK" version >/dev/null 2>&1 || fail "the node's containerd does not answer on $CTD_SOCK"
echo "  -> OK"

echo "[precondition] the node's images as the CRI sees them, which of them are in use and which are idle, what is pinned, and a control of the tools (tag and untag a name of a shared image)..."
sudo env STATE_DIR="$STATE_DIR" CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF' || exit 1
import json, os, subprocess, sys
E = os.environ
S = E["CTD_SOCK"]
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
def run(*a):
    return subprocess.run(list(a), capture_output=True, text=True)
def crictl(*a):
    return json.loads(run("crictl", "--runtime-endpoint", "unix://" + S, "--image-endpoint", "unix://" + S, *a, "-o", "json").stdout or "{}")
def ctr(*a, ns="k8s.io"):
    return run("ctr", "-a", S, "-n", ns, *a)
images = {i["id"]: i for i in crictl("images").get("images", [])}
want = {i["id"]: sorted(i["names"]) for i in st["images"]}
if sorted(images) != sorted(want): fail("the CRI lists %d images, expected %d" % (len(images), len(want)))
for iid, names in want.items():
    if sorted(images[iid]["repoTags"]) != names: fail("the image %s has the names %s, expected %s" % (iid[:19], sorted(images[iid]["repoTags"]), names))
n_names = sum(len(v) for v in want.values())
cs = crictl("ps", "-a").get("containers", [])
used = sorted({c["imageRef"] for c in cs})
id_of = {n: i["id"] for i in st["images"] for n in i["names"]}
if used != sorted(id_of[n] for n in st["used"]): fail("the containers use the images %s, expected the two of the workload" % [u[:19] for u in used])
target_ids = {id_of[n] for n in st["target"]}
if target_ids & set(used): fail("an image to be pruned is in use")
if not images[id_of[st["pause"]]].get("pinned"): fail("the sandbox image %s is not pinned" % st["pause"])
shared = [i for i in st["images"] if len(i["names"]) > 1]
if len(shared) != 1: fail("expected one image with two names")
if any(c["state"] != "CONTAINER_RUNNING" for c in cs): fail("a container of the workload is not running")
idle = [i for i in images.values() if i["id"] not in used and not i.get("pinned")]
idle_names = sorted(t for i in idle for t in i["repoTags"])
need_stay = [n for n in st["keep"] if n not in st["used"] and n != st["pause"]]
if not set(need_stay) <= set(idle_names): fail("the images that must stay are not all idle")
# every blob of the images with their own layer is in the content store
blobs = set(ctr("content", "ls", "-q").stdout.split())
for i in st["images"]:
    for b in i["own_blobs"]:
        if b not in blobs: fail("the blob %s of %s is missing from the content store" % (b[:19], i["names"][0]))
other = ctr("images", "ls", "-q", ns="bench-other").stdout.split()
if st["other"][0]["names"][0] not in other: fail("the image of the other namespace is missing")
# control: a second name for the shared image is added and removed with ctr; the image and its other names stay
sh = shared[0]; alias = "registry.bench.local/scratch/probe:dev-0"
if ctr("images", "tag", sh["names"][0], alias).returncode != 0: fail("ctr images tag failed")
if ctr("images", "rm", alias).returncode != 0: fail("ctr images rm of the scratch name failed")
after = {i["id"]: sorted(i["repoTags"]) for i in crictl("images").get("images", [])}
if after.get(sh["id"]) != sorted(sh["names"]): fail("removing a scratch name of the shared image changed its names: %s" % after.get(sh["id"]))
print("  -> OK: %d image names on %d images; used by the two running containers: web:dev-100 and api:dev-100; pinned: the sandbox image %s; idle: %d names, among them the 2 on the keep list; the shared image carries 2 names (removing one name with ctr leaves the other); every image has blobs of its own" % (n_names, len(images), st["pause"], len(idle_names)))
PYEOF

echo "[precondition] the lab is as the task describes: idle images with the dev- tag next to images that must stay; nothing pruned yet."
