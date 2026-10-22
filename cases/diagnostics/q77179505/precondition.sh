#!/bin/bash
# Precondition oracle: the lab is as setup.sh made it and the problem is there:
#  - the lab's files are unchanged, the node's containerd is the 1.7.20 of the lab and answers;
#  - the question's symptom: `ctr snapshot ls` and `ctr container list` (namespace default) show nothing, while the node holds images, snapshots and a container in the namespaces k8s.io and moby;
#  - the scanner's file (usr/lib/jvm/java-1.8.0-openjdk/release) is in exactly four numbered directories of the snapshotter, and the names of the directories say nothing about images;
#  - the shared layer: the two JDK images have the same first layer (one snapshot, two images), the third image has none of it; the same layer imported in the other namespace is a directory of its own;
#  - the way to the answer exists: a temporary view of a snapshot and its mount give the directory of that snapshot (removed again, the node is as before), and for the four directories the result is the one setup recorded;
#  - the Dockerfile is not in the images: what the configs keep is the history (created_by), no FROM, no complete file.

CASE_ID="bench77179505"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SNAP="$LIB/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
CTR=(sudo "$LIB/bin/ctr")
fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the lab's files and the node's containerd..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
"${CTR[@]}" version 2>/dev/null | grep -q "Version:  v1.7.20" || fail "the node's containerd does not answer as v1.7.20"
sudo bash "$STATE_DIR/state.sh" | diff -q - <(sudo cat "$STATE_DIR/before.txt") >/dev/null || fail "the node is not as setup left it"

echo "[precondition] the symptom: nothing in the namespace default, a lot in the others..."
[ "$("${CTR[@]}" snapshots ls | wc -l)" = 1 ] || fail "ctr snapshot ls (default) shows snapshots"
[ "$("${CTR[@]}" containers ls | wc -l)" = 1 ] || fail "ctr container list (default) shows containers"
[ "$("${CTR[@]}" images ls | wc -l)" = 1 ] || fail "ctr image ls (default) shows images"
"${CTR[@]}" namespaces ls -q | sort | tr '\n' ' ' | grep -qx "k8s.io moby " || fail "the namespaces of the node are not k8s.io and moby"

sudo python3 -I - "$SNAP" "$STATE_DIR/truth.json" "$LIB/bin/ctr" <<'PYEOF' || fail "the lab does not hold what it was built to hold"
import glob
import json
import re
import subprocess
import sys

snap, truth_path, ctr_bin = sys.argv[1:4]
MARK = "usr/lib/jvm/java-1.8.0-openjdk/release"
truth = json.load(open(truth_path))
bad = []


def ctr(ns, *args):
    return subprocess.run([ctr_bin, "-n", ns] + list(args), capture_output=True, text=True, check=True).stdout


def fail(msg):
    bad.append(msg)
    print("[precondition] FAIL: " + msg)


# 1. the scanner's file: four directories, none of them says what it belongs to
found = sorted(p[len(snap) + 1:].split("/")[0] for p in glob.glob("%s/*/fs/%s" % (snap, MARK)))
want = sorted(e["dir"] for e in truth["entries"])
if found != want or len(found) != 4:
    fail("the scanner's file is in the directories %s, setup recorded %s" % (found, want))
else:
    print("[precondition] the scanner's file is in 4 directories of the snapshotter (%s); they are numbers, nothing in them names an image" % ", ".join(sorted(found, key=int)))

# 2. the shared layer
shared = [e for e in truth["entries"] if e["kind"] == "layer"]
by_ns = {e["namespace"]: e for e in shared}
if sorted(by_ns) != ["k8s.io", "moby"] or len(by_ns["k8s.io"]["images"]) != 2 or len(by_ns["moby"]["images"]) != 1 or by_ns["k8s.io"]["key"] != by_ns["moby"]["key"] or by_ns["k8s.io"]["dir"] == by_ns["moby"]["dir"]:
    fail("the shared JDK layer is not one snapshot with two images in k8s.io and a directory of its own in moby")
else:
    print("[precondition] the JDK layer is one snapshot (dir %s) of 2 images in k8s.io, and again a directory of its own (dir %s, 1 image) in moby" % (by_ns["k8s.io"]["dir"], by_ns["moby"]["dir"]))
act = {e["key"]: e for e in truth["entries"] if e["kind"] == "active"}
if not (act["orders-api-7d9f"]["containers"] == ["orders-api-7d9f"] and not act["orders-api-7d9f"]["unreferenced"] and act["stale-extract-0"]["unreferenced"] and not act["stale-extract-0"]["containers"]):
    fail("the writable layers are not a container's and a stale one")
else:
    print("[precondition] the two writable layers: the one of the container orders-api-7d9f (dir %s), and a stale one that no container names (dir %s)" % (act["orders-api-7d9f"]["dir"], act["stale-extract-0"]["dir"]))

# 3. the way to the directory: a temporary view and its mount (the same as setup's record; the view is removed)
for e in truth["entries"]:
    ns, key = e["namespace"], e["key"]
    if e["kind"] == "layer":
        ctr(ns, "snapshots", "view", "pre-view", key)
        try:
            out = ctr(ns, "snapshots", "mounts", "/x", "pre-view")
        finally:
            ctr(ns, "snapshots", "rm", "pre-view")
        m = re.search(r"%s/(\d+)/fs" % re.escape(snap), out)
    else:
        m = re.search(r"upperdir=%s/(\d+)/fs" % re.escape(snap), ctr(ns, "snapshots", "mounts", "/x", key))
    if not m or m.group(1) != e["dir"]:
        fail("%s %s: the mount names the directory %s, setup recorded %s" % (ns, key[:19], m and m.group(1), e["dir"]))
if not bad:
    print("[precondition] a temporary view and its mount name the directory of a snapshot: the 4 directories are found that way (the views were removed)")

# 4. the Dockerfile
for d, hist in truth["history"].items():
    if not hist or any(h.upper().startswith("FROM ") for h in hist):
        fail("the history of %s is not what the lab keeps" % d[:19])
cfg = json.loads(ctr("k8s.io", "content", "get", json.loads(ctr("k8s.io", "content", "get", sorted(truth["namespaces"]["k8s.io"]["images"])[0]))["config"]["digest"]))
if "Dockerfile" in json.dumps(cfg) or "labels" in json.dumps(cfg.get("config", {})).lower():
    fail("an image config carries more than the history")
if not bad:
    print("[precondition] the configs keep a history of created_by lines (%d images), no FROM line and no Dockerfile" % len(truth["history"]))
sys.exit(1 if bad else 0)
PYEOF
sudo bash "$STATE_DIR/state.sh" | diff -q - <(sudo cat "$STATE_DIR/before.txt") >/dev/null || fail "the precondition changed the node"
echo "[precondition] OK: the symptom is there (nothing in default), the scanner's file is in 4 directories, the shared layer is one snapshot of two images, and the answer can be reached with views and mounts."
