#!/bin/bash
# Precondition: the question's situation. The node runs ten containers of one image (a big layer of incompressible data and a small one); `du` of every rootfs shows about the whole image,
# and everything together (the sum of the du's) is many times what the snapshotter's directory really occupies; no container has copied the big file up; there is no dupreport yet.
CASE_ID="bench76627556"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
SNAPDIR="$LIB/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
ROOTS="$RUN/containerd/io.containerd.runtime.v2.task/k8s.io"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program or the configuration of the node changed since setup"
[ ! -e "$LIB/dupreport" ] || fail "$LIB/dupreport exists before the solution"
"$LIB/bin/nodectl" status >/dev/null 2>&1 || sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
sudo "$LIB/bin/ctr" -n k8s.io images ls -q | grep -qx "$CASE_ID.local/ml-scraper:latest" || fail "the image is missing"
n=$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))))" <(sudo cat "$STATE_DIR/initial.json"))
[ "$n" = 10 ] || fail "setup made $n containers instead of 10"
[ "$(sudo "$LIB/bin/ctr" -n k8s.io tasks ls | grep -c RUNNING)" = 10 ] || fail "the ten containers do not all run"

res=$(sudo python3 - "$STATE_DIR" "$ROOTS" "$SNAPDIR" <<'PY'
import json, os, re, subprocess, sys
state, roots, snap = sys.argv[1:4]
ids = [c["id"] for c in json.load(open(state + "/initial.json"))]
big = int(open(state + "/bigmb").read()) << 20
def du(p, *o):
    return int(subprocess.check_output(["du", "-s", "-B1", *o, p]).split()[0])
mi = open("/proc/self/mountinfo").read().splitlines()
lowers, uppers, dus = set(), [], []
for i in ids:
    root = f"{roots}/{i}/rootfs"
    line = [l for l in mi if l.split()[4] == root]
    if not line or " overlay " not in line[0]:
        print("FAIL: no overlay mount at " + root); sys.exit(1)
    o = dict(x.split("=", 1) for x in line[0].split(" - ")[1].split()[2].split(",") if "=" in x)
    lowers.add(o["lowerdir"]); uppers.append(o["upperdir"])
    d = du(root); dus.append(d)
    if not (big <= d <= big * 1.1):
        print(f"FAIL: du of {root} is {d}, not about the image ({big})"); sys.exit(1)
    if os.path.exists(o["upperdir"] + "/big.bin"):
        print("FAIL: " + i + " has a copy of big.bin in its upper"); sys.exit(1)
if len(lowers) != 1 or len(set(uppers)) != 10:
    print("FAIL: the containers do not share one lowerdir list with ten uppers of their own"); sys.exit(1)
phys = du(snap)
if not (big <= phys <= big * 1.2) or sum(dus) < 8 * phys:
    print(f"FAIL: physical {phys}, sum of du {sum(dus)}, image {big}"); sys.exit(1)
print(f"image {big >> 20} MiB: 10 x du = {sum(dus) >> 20} MiB, the snapshots directory really holds {phys >> 20} MiB")
PY
) || fail "$res"
echo "[precondition] PASS: $res"
