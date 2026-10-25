#!/bin/bash
# Precondition: the question's node. Three images (two pulled through the CRI, one built with nerdctl), eight image records in containerd's namespace k8s.io (three per pulled image, two per built
# image), three different IDs in `nerdctl images`; the content store and the snapshotter hold each image once (far less than the lines of the listing add up to); BuildKit's own store holds
# the built image's blobs again; there is no imgreport yet.
CASE_ID="bench76424192"
LIB="/var/lib/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program or the configuration of the node changed since setup"
[ ! -e "$LIB/imgreport" ] || fail "$LIB/imgreport exists before the solution"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node does not run (containerd, registry, buildkitd)"
res=$(sudo python3 - "$LIB" <<'PY'
import os, re, subprocess, sys
lib = sys.argv[1]
def run(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout
def du(p):
    return int(run("du", "-s", "-B1", p).split()[0])
rows = [l.split() for l in run(lib + "/bin/nerdctl", "images").splitlines()[1:]]
ids = {r[2] for r in rows}
recs = [l.split()[0] for l in run(lib + "/bin/ctr", "-n", "k8s.io", "images", "ls").splitlines()[1:]]
if len(rows) != 8 or len(ids) != 3 or len(recs) != 8:
    print(f"FAIL: nerdctl shows {len(rows)} rows with {len(ids)} IDs, containerd has {len(recs)} records (expected 8, 3, 8)"); sys.exit(1)
crictl = run(lib + "/bin/crictl", "images").splitlines()[1:]
if len(crictl) != 3:
    print(f"FAIL: crictl lists {len(crictl)} images, expected 3"); sys.exit(1)
sizes = [float(r[-2]) * {"KiB": 1 << 10, "MiB": 1 << 20, "GiB": 1 << 30}[r[-1]] for r in (l.split()[-4:] for l in run(lib + "/bin/nerdctl", "images").splitlines()[1:])]
listed = sum(sizes)
cs = du(lib + "/containerd/io.containerd.content.v1.content")
sn = du(lib + "/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots")
if not (cs * 2 < listed * 1.0 and sn * 2 < listed):
    print(f"FAIL: the lines of the listing add up to {listed:.0f}, content store {cs}, snapshots {sn}: the stores do not hold the images once"); sys.exit(1)
bk = [d for d in __import__("glob").glob(lib + "/buildkit/*/content/blobs/sha256")]
mine = set(os.listdir(lib + "/containerd/io.containerd.content.v1.content/blobs/sha256"))
common = mine & set(os.listdir(bk[0])) if bk else set()
if len(common) < 3:
    print(f"FAIL: BuildKit's store has {len(common)} blobs of containerd's, expected the built image's manifest, config and layer"); sys.exit(1)
print(f"8 records, 3 IDs; the listing adds up to {listed/2**20:.1f} MiB, containerd's content store holds {cs/2**20:.1f} MiB and its snapshots {sn/2**20:.1f} MiB; BuildKit's store has {len(common)} of the same blobs")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
