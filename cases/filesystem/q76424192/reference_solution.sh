#!/bin/bash
# Reference: imgreport reads the image records (ctr, namespace k8s.io), follows each target through the content store (manifest, config, layers), and measures allocated blocks, each inode once;
# BuildKit's store is another directory that is compared by blob digest. Nothing is written or removed.
set -e
LIB=/var/lib/bench76424192
sudo tee "$LIB/imgreport" >/dev/null <<'PY_EOF'
#!/usr/bin/env python3
import glob, json, os, re, subprocess

LIB = "/var/lib/bench76424192"
CS = LIB + "/containerd/io.containerd.content.v1.content"
SNAP = LIB + "/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
BK = LIB + "/buildkit"
BLOBS = CS + "/blobs/sha256"


def alloc(p):
    return os.lstat(p).st_blocks * 512


def usage(top):
    """allocated bytes (512 * st_blocks) of everything under top (top included), each inode once"""
    seen, total = set(), 0
    def add(p):
        nonlocal total
        st = os.lstat(p)
        if (st.st_dev, st.st_ino) not in seen:
            seen.add((st.st_dev, st.st_ino))
            total += st.st_blocks * 512
    add(top)
    for dp, dns, fns in os.walk(top):
        for n in dns + fns:
            add(os.path.join(dp, n))
    return total


def blob(d):
    return os.path.join(BLOBS, d.split(":", 1)[1])


def closure(d):
    """the digests a target needs: itself, and for a manifest its config and layers (an index: the manifests it lists that are in the store)"""
    out = [d]
    if not os.path.exists(blob(d)):
        return out
    doc = json.load(open(blob(d)))
    if "manifests" in doc:
        for m in doc["manifests"]:
            if os.path.exists(blob(m["digest"])):
                out += closure(m["digest"])
    else:
        out.append(doc["config"]["digest"])
        out += [l["digest"] for l in doc["layers"]]
    return out


def kind(name):
    return "image-id" if name.startswith("sha256:") else ("repo-digest" if "@sha256:" in name else "tag")


out = subprocess.run([LIB + "/node/bin/ctr", "-a", "/run/bench76424192/containerd.sock", "-n", "k8s.io", "images", "ls"], capture_output=True, text=True, check=True).stdout
recs = [l.split()[:3] for l in out.splitlines()[1:] if l.strip()]
by = {}
for name, _, digest in recs:
    by.setdefault(digest, []).append(name)
groups, listed = [], 0
layer_users = {}
for digest in sorted(by):
    blobs = sorted(set(closure(digest)))
    doc = json.load(open(blob(digest)))
    manifest = doc if "layers" in doc else json.load(open(blob(next(m["digest"] for m in doc["manifests"] if os.path.exists(blob(m["digest"]))))))
    for l in manifest["layers"]:
        layer_users.setdefault(l["digest"], set()).add(digest)
    cb = sum(alloc(blob(b)) for b in blobs)
    names = sorted(by[digest])
    listed += cb * len(names)
    groups.append({"target_digest": digest, "image_id": manifest["config"]["digest"], "records": [{"name": n, "kind": kind(n)} for n in names], "blob_digests": blobs, "content_bytes": cb})
referenced = {b for g in groups for b in g["blob_digests"]}
# the records that would stay if every group kept one: the same targets, so the same blobs
kept = {b for g in groups for b in g["blob_digests"]}
freed = sum(alloc(blob(b)) for b in referenced - kept)
unref = sum(alloc(os.path.join(BLOBS, f)) for f in os.listdir(BLOBS) if "sha256:" + f not in referenced)
shared = [{"digest": d, "bytes": alloc(blob(d)), "groups": sorted(u)} for d, u in sorted(layer_users.items()) if len(u) > 1]
bkblobs = (glob.glob(BK + "/*/content/blobs/sha256") or [None])[0]
common = sorted(f for f in os.listdir(bkblobs) if os.path.exists(os.path.join(BLOBS, f))) if bkblobs else []
print(json.dumps({
    "records_total": len(recs), "groups_total": len(groups), "alias_records": len(recs) - len(groups),
    "groups": groups, "listed_bytes": listed,
    "content_store_bytes": usage(CS), "snapshots_bytes": usage(SNAP),
    "freed_by_removing_alias_records_bytes": freed, "unreferenced_content_bytes": unref,
    "shared_layers": shared, "shared_layers_saved_bytes": sum(s["bytes"] * (len(s["groups"]) - 1) for s in shared),
    "buildkit": {"root": BK, "bytes": usage(BK), "blobs_also_in_containerd": ["sha256:" + f for f in common], "shared_blob_bytes": sum(alloc(os.path.join(BLOBS, f)) for f in common)},
}, indent=1))
PY_EOF
sudo chmod 755 "$LIB/imgreport"
