#!/bin/bash
# Reference solution: what looks like three images is three NAMES (records) of one image: the tag, name@<manifest digest> and the image's id (the config digest) all point at the same manifest; containerd's content store
# keeps ONE blob per digest (manifest, config, each layer) and the layers are unpacked once into committed snapshots, whatever the number of records or pods. What does grow with each Pod is its writable layer (the
# upper directory of its active snapshot). The registry's access log shows what was really transferred: one manifest by tag (HEAD), one by digest, one GET per blob - nothing again when a Pod is created.
# imgreport measures all of that, reading only (ctr's list/info/mounts commands, files, the log), and prints it as JSON.
set -e
LIB="/var/lib/bench67820623"
sudo tee "$LIB/imgreport" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import re
import stat
import subprocess

LIB = "/var/lib/bench67820623"
CTR = [LIB + "/node/bin/ctr", "-a", "/run/bench67820623/containerd.sock", "-n", "k8s.io"]


def ctr(*args):
    return subprocess.run(CTR + list(args), check=True, capture_output=True, text=True).stdout


records = {}
for line in ctr("images", "ls").splitlines()[1:]:
    f = line.split()
    records[f[0]] = f[2]

bdir = LIB + "/containerd/io.containerd.content.v1.content/blobs/sha256"
sizes = [os.path.getsize(os.path.join(bdir, n)) for n in os.listdir(bdir)]
snaps = {"committed": 0, "active": 0}
for line in ctr("snapshots", "ls").splitlines()[1:]:
    kind = line.split()[-1].lower()
    if kind in snaps:
        snaps[kind] += 1


def rw_bytes(key):
    out = ctr("snapshots", "mounts", "/nonexistent", key)
    upper = re.search(r"upperdir=([^,\s]+)", out).group(1)
    total = 0
    for root, _, files in os.walk(upper):
        for n in files:
            st = os.lstat(os.path.join(root, n))
            if stat.S_ISREG(st.st_mode):
                total += st.st_size
    return total


containers = {}
for cid in ctr("containers", "ls", "-q").split():
    info = json.loads(ctr("containers", "info", cid))
    containers[cid] = {"image": info["Image"], "rw_bytes": rw_bytes(info["SnapshotKey"])}

reg = {"blob_gets": 0, "blob_bytes": 0, "manifest_gets": 0, "manifest_heads": 0}
for line in open("/run/bench67820623/registry.log", errors="replace"):
    m = re.match(r'^\S+ - - \[[^\]]+\] "(GET|HEAD) (\S+) HTTP/[\d.]+" (\d+) (\d+) ', line)
    if not m or m.group(3) != "200":
        continue
    method, path, _, written = m.groups()
    if "/blobs/" in path and method == "GET":
        reg["blob_gets"] += 1
        reg["blob_bytes"] += int(written)
    elif "/manifests/" in path:
        reg["manifest_gets" if method == "GET" else "manifest_heads"] += 1

print(json.dumps({"records": records, "blobs": {"count": len(sizes), "bytes": sum(sizes)}, "snapshots": snaps, "containers": containers, "registry": reg}, indent=1, sort_keys=True))
PYEOF
sudo chmod 755 "$LIB/imgreport"
sudo "$LIB/imgreport"
