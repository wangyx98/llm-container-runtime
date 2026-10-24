#!/bin/bash
# Precondition oracle: the initial state is the question's, measured here:
#  - the lab's files are as setup left them; the node (the lab's containerd 1.6.17 with the CRI) and the registry (distribution 2.8.3) are running as setup left them;
#  - the node knows two images from the CRI pulls, each under THREE records (name:tag, name@<manifest digest>, the config digest) that point at one manifest digest, and a content store of 10 blobs;
#  - two pods of bench/a:1 run: four containers (two sandboxes), four active snapshots, two writable layers with 1 and 2 MiB; the registry's log has exactly the two pulls and nothing else;
#  - the tool the task asks for does not exist yet.

CASE_ID="bench67820623"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
RHOST="127.0.0.1:5067"
fail() { echo "[precondition] FAIL: $*"; exit 1; }
ctr() { sudo timeout -k 3 60 "$LIB/node/bin/ctr" -a "$RUN/containerd.sock" -n k8s.io "$@"; }

echo "[precondition] the lab's files, the node and the registry..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab is not as setup left it"
CPID=$(sudo cat "$RUN/containerd.pid" 2>/dev/null)
[ -n "$CPID" ] && [ "$(sudo readlink "/proc/$CPID/exe")" = "$(sudo cat "$STATE_DIR/containerd.exe")" ] || fail "the node's containerd is not running"
RPID=$(sudo cat "$STATE_DIR/registry.pid")
[ "$(sudo readlink "/proc/$RPID/exe" 2>/dev/null)" = "$LIB/registry/registry" ] || fail "the registry is not running"
timeout 5 bash -c "exec 3<>/dev/tcp/${RHOST%:*}/${RHOST#*:}" 2>/dev/null || fail "the registry does not accept connections"   # a bare connect: no request, no line in the log
sudo "$LIB/bin/crictl" version 2>/dev/null | grep -q "RuntimeVersion:  v1.6.17" || fail "the CRI of the node does not answer"
[ ! -e "$LIB/imgreport" ] || fail "imgreport exists before the solution"

echo "[precondition] the images: three records for one manifest each, one blob per digest..."
ctr images ls | awk 'NR>1 {print $1, $3}' | python3 -c "
import sys
rec = dict(l.split() for l in sys.stdin)
assert len(rec) == 6, 'records: %d' % len(rec)
by = {}
for n, d in rec.items():
    by.setdefault(d, []).append(n)
assert sorted(len(v) for v in by.values()) == [3, 3], 'not three records per manifest'
for v in by.values():
    assert sum(1 for n in v if n.startswith('sha256:')) == 1 and sum(1 for n in v if '@sha256:' in n) == 1, 'records are not tag, digest and id'" 2>&1 | tail -1 | grep -q . && fail "the node does not hold two images under three records each"
[ "$(sudo find "$LIB/containerd/io.containerd.content.v1.content/blobs/sha256" -type f | wc -l)" = 10 ] || fail "the content store does not hold 10 blobs"

echo "[precondition] the pods, the snapshots, the writable layers..."
[ "$(ctr containers ls -q | wc -l)" = 4 ] || fail "the node does not have four containers"
[ "$(ctr snapshots ls | awk 'NR>1 && $NF=="Active"' | wc -l)" = 4 ] || fail "the node does not have four active snapshots"
sizes=$(for f in $(sudo find "$LIB/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots" -name blob.bin); do sudo stat -c %s "$f"; done | sort -n | tr '\n' ' ')
[ "$sizes" = "1048576 2097152 " ] || fail "the writable layers do not hold 1 and 2 MiB (got: $sizes)"

echo "[precondition] the registry's log: the two pulls and nothing else..."
sudo cat "$RUN/registry.log" | python3 -c "
import re, sys
lines = [l for l in sys.stdin if re.match(r'^\S+ - - \[', l)]
req = [re.search(r'\"(GET|HEAD) (\S+) ', l).groups() for l in lines]
assert sum(1 for m, p in req if '/blobs/' in p and m == 'GET') == 8, 'blob GETs'
assert sum(1 for m, p in req if '/manifests/' in p and m == 'HEAD') == 2 and sum(1 for m, p in req if '/manifests/' in p and m == 'GET') == 2, 'manifest requests'
assert len(req) == 12, 'other requests'" 2>&1 | tail -1 | grep -q . && fail "the registry's log is not the two pulls"

echo "[precondition] OK: two images, six records, 10 blobs, four active snapshots, two writable layers; the registry served 12 requests for two pulls."
