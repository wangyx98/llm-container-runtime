#!/bin/bash
# Oracle: /var/lib/bench77179505/out/report.json says, for every directory of the overlayfs snapshotter that holds the scanner's file (usr/lib/jvm/java-1.8.0-openjdk/release), what it is and what it belongs to:
#   {"snapshots": [{"dir", "namespace", "kind": "layer"|"active", "key", "images": [manifest digests], "containers": [ids], "unreferenced": bool}, ...],
#    "dockerfile": {"status": "unrecoverable", "history": {image digest: [created_by of its config]}}}
# Checked against truth.json that setup made (from the snapshotter's own records, and the files):
#   - exactly the four directories; for each one the namespace, the kind, the key (the chain ID of a layer, the name of an active snapshot), ALL the images (the shared layer has two in k8s.io, one in moby; the
#     writable layer of the container only the image of its parent chain; the stale one the two images of its parent), the containers and "unreferenced";
#   - the Dockerfile is marked "unrecoverable" and the history, for every image the report names, is the real one (no invented FROM or RUN lines);
#   - the node is as it was: every snapshot, image and container of every namespace, the scanner's files (nothing removed, no temporary view left behind), the lab's files, the same containerd.

CASE_ID="bench77179505"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's files and the node's containerd..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$LIB/node/bin/containerd" ] || fail "the node's containerd (the program of the lab) is not running"
[ -f "$LIB/out/report.json" ] || fail "there is no report $LIB/out/report.json"

echo "[oracle] the report against the record of the lab..."
sudo python3 -I - "$LIB/out/report.json" "$STATE_DIR/truth.json" <<'PYEOF' || exit 1
import json
import sys

try:
    rep = json.load(open(sys.argv[1]))
except ValueError as e:
    print("[oracle] FAIL: the report is not JSON: %s" % e)
    sys.exit(1)
truth = json.load(open(sys.argv[2]))
bad = []


def fail(msg):
    bad.append(msg)
    print("[oracle] FAIL: " + msg)


snaps = rep.get("snapshots") if isinstance(rep, dict) else None
if not isinstance(snaps, list) or not all(isinstance(e, dict) for e in snaps):
    print('[oracle] FAIL: the report has no list "snapshots" of objects')
    sys.exit(1)
by_dir = {}
for e in snaps:
    d = str(e.get("dir"))
    if d in by_dir:
        fail("the directory %s is in the report twice" % d)
    by_dir[d] = e
for t in sorted(truth["entries"], key=lambda e: int(e["dir"])):
    e = by_dir.pop(t["dir"], None)
    what = "dir %s (%s, %s %s)" % (t["dir"], t["namespace"], t["kind"], t["key"][:19] if t["kind"] == "layer" else t["key"])
    if e is None:
        fail("%s is not in the report" % what)
        continue
    problems = []
    for f in ("namespace", "kind", "key"):
        if e.get(f) != t[f]:
            problems.append("%s is %r" % (f, e.get(f)))
    got, want = e.get("images"), t["images"]
    if not isinstance(got, list):
        problems.append("images is not a list")
    elif sorted(set(got)) != want:
        problems.append("images: %d named, %d missing, %d wrong" % (len(set(got)), len(set(want) - set(got)), len(set(got) - set(want))))
    elif len(got) != len(set(got)):
        problems.append("an image is named twice")
    if sorted(e.get("containers") or []) != t["containers"] or not isinstance(e.get("containers"), list):
        problems.append("containers: %r" % (e.get("containers"),))
    if e.get("unreferenced") is not t["unreferenced"]:
        problems.append("unreferenced is %r" % (e.get("unreferenced"),))
    if problems:
        fail("%s: %s" % (what, "; ".join(problems)))
    else:
        print("[oracle] %s: namespace, kind, key, %d image(s), %d container(s), unreferenced=%s: ok" % (what, len(want), len(t["containers"]), str(t["unreferenced"]).lower()))
for d in sorted(by_dir):
    fail("the report has the directory %s, which does not hold the scanner's file" % d)

df = rep.get("dockerfile")
if not isinstance(df, dict) or df.get("status") != "unrecoverable":
    fail('"dockerfile" is not {"status": "unrecoverable", ...}: a complete Dockerfile is not in an image, only its history is (status %r)' % (df.get("status") if isinstance(df, dict) else df,))
else:
    hist = df.get("history")
    named = {x for t in truth["entries"] for x in t["images"]}
    if not isinstance(hist, dict) or sorted(hist) != sorted(named):
        fail("dockerfile.history is not an object with an entry for each of the %d images the snapshots belong to" % len(named))
    else:
        wrong = [x for x in named if hist[x] != truth["history"][x]]
        extra = [k for k in df if k not in ("status", "history", "note")]
        if wrong:
            fail("the history of %d image(s) is not the one in the image's config" % len(wrong))
        elif extra:
            fail("dockerfile has fields beyond status, history and note: %s" % ", ".join(extra))
        else:
            print("[oracle] dockerfile: unrecoverable, with the real history of %d images: ok" % len(named))
sys.exit(1 if bad else 0)
PYEOF

echo "[oracle] the node after the task..."
sudo bash "$STATE_DIR/state.sh" > "$WORK_DIR/after.txt" 2>&1
if ! sudo diff "$STATE_DIR/before.txt" "$WORK_DIR/after.txt" > "$WORK_DIR/state.diff"; then
    echo "[oracle] FAIL: the node is not as it was (the report is read-only: nothing removed, nothing left behind):"
    sed -n '1,8p' "$WORK_DIR/state.diff" | cut -c1-160
    exit 1
fi
echo "[oracle] OK: the four directories are attributed to all their images, containers and namespaces, the Dockerfile is marked unrecoverable, the node was not touched."
