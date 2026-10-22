#!/bin/bash
# Reference solution: a read-only report of where the scanner's file (usr/lib/jvm/java-1.8.0-openjdk/release) is and what it belongs to, written to /var/lib/bench77179505/out/report.json.
#  - `ctr snapshot ls` and `ctr container list` look at the namespace "default" only; kubelet and the CRI keep everything in "k8s.io": every namespace is walked (ctr namespaces ls);
#  - the numbered directories of the snapshotter are not the keys of the snapshots; the directory of a committed snapshot is the first directory of the mount of a temporary view of it (removed again), the directory
#    of an active one is the upperdir of its mount;
#  - the key of a committed snapshot is the chain ID of a layer of an image: chain(1) = diff_id(1), chain(n) = sha256("chain(n-1) diff_id(n)"); a layer shared by two images is ONE snapshot with two images;
#  - an active snapshot belongs to a container when a container record names it (SnapshotKey), else it is unreferenced; its images are those that have its parent among their chain IDs;
#  - what remains of the Dockerfile in an image is its history (created_by of the config): that is all that is reported, the Dockerfile itself is marked as not recoverable.
set -e
python3 - <<'PYEOF'
import hashlib
import json
import re
import subprocess

LIB = "/var/lib/bench77179505"
SNAP = LIB + "/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
MARK = "usr/lib/jvm/java-1.8.0-openjdk/release"


def ctr(ns, *args):
    return subprocess.run(["sudo", LIB + "/bin/ctr", "-n", ns] + list(args), capture_output=True, text=True, check=True).stdout


def rows(text):
    return [l.split() for l in text.strip().splitlines()[1:]]


def dir_of(ns, key, kind):
    if kind == "Active":
        out = ctr(ns, "snapshots", "mounts", "/x", key)
        return re.search(r"upperdir=%s/(\d+)/fs" % SNAP, out).group(1)
    ctr(ns, "snapshots", "view", "tmp-view", key)
    try:
        out = ctr(ns, "snapshots", "mounts", "/x", "tmp-view")
    finally:
        ctr(ns, "snapshots", "rm", "tmp-view")
    return re.search(r"%s/(\d+)/fs" % SNAP, out).group(1)


NAMESPACES = ctr("default", "namespaces", "ls", "-q").split()
found = {p[len(SNAP) + 1:].split("/")[0] for p in subprocess.run(["sudo", "find", SNAP, "-path", "*/fs/" + MARK], capture_output=True, text=True).stdout.split()}      # the snapshotter's directory is root's
entries, history = [], {}
for ns in NAMESPACES:
    images = {}
    for r in rows(ctr(ns, "images", "ls")):
        digest = r[2]
        if digest in images:
            continue
        manifest = json.loads(ctr(ns, "content", "get", digest))
        config = json.loads(ctr(ns, "content", "get", manifest["config"]["digest"]))
        chain = []
        for d in config["rootfs"]["diff_ids"]:
            chain.append(d if not chain else "sha256:" + hashlib.sha256((chain[-1] + " " + d).encode()).hexdigest())
        images[digest] = {"chain": chain, "history": [h["created_by"] for h in config.get("history", [])]}
    containers = {r[0]: json.loads(ctr(ns, "containers", "info", r[0]))["SnapshotKey"] for r in rows(ctr(ns, "containers", "ls"))}
    for r in rows(ctr(ns, "snapshots", "ls")):
        key, kind = r[0], r[-1]
        parent = r[1] if len(r) >= 3 else ""
        d = dir_of(ns, key, kind)
        if d not in found:
            continue
        if kind == "Active":
            owners = sorted(c for c, k in containers.items() if k == key)
            digests = sorted(x for x, i in images.items() if parent in i["chain"])
            entry = {"dir": d, "namespace": ns, "kind": "active", "key": key, "images": digests, "containers": owners, "unreferenced": not owners}
        else:
            digests = sorted(x for x, i in images.items() if key in i["chain"])
            entry = {"dir": d, "namespace": ns, "kind": "layer", "key": key, "images": digests, "containers": [], "unreferenced": False}
        entries.append(entry)
        for x in digests:
            history[x] = images[x]["history"]
report = {"snapshots": sorted(entries, key=lambda e: int(e["dir"])), "dockerfile": {"status": "unrecoverable", "history": history}}
json.dump(report, open(LIB + "/out/report.json", "w"), indent=1)
print("[solution] %d snapshot directories hold the scanner's file; report in %s/out/report.json" % (len(entries), LIB))
PYEOF
