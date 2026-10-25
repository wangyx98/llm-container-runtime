#!/bin/bash
# Precondition: the question's situation on the lab's node. In the container of the Pod purger (the node's containerd socket mounted at /run/containerd/containerd.sock) `ctr images ls` answers with nothing and
# exit status 0 (default namespace), `ctr -n k8s.io` and crictl list the node's images; the image the Pod's own container runs is among them. Controls: the images to purge (scratch/old:1, :2) and the ones to
# keep are all there, the job's directory is empty, the node's containers run.
CASE_ID="bench66960498"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program or the configuration of the node changed since setup"
sudo "$LIB/bin/nodectl" status >/dev/null 2>&1 || fail "the node's containerd does not run"
res=$(sudo python3 - "$LIB" "$STATE_DIR" <<'PY'
import json, os, subprocess, sys
lib, state = sys.argv[1:3]
crictl = lib + "/bin/crictl"
truth = json.load(open(state + "/truth.json"))
cid = truth["containers"]["main@purger"]
s = "/run/containerd/containerd.sock"


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout.strip()


def inpod(*a):
    return sh(crictl, "exec", cid, *a)


rc, out = inpod("/ctr", "-a", s, "images", "ls", "-q")
if rc != 0 or out:
    print("FAIL: ctr in the Pod's container should answer with nothing and status 0 (default namespace): rc=%d %r" % (rc, out[:100])); sys.exit(1)
rc, out = inpod("/ctr", "-a", s, "-n", "k8s.io", "images", "ls", "-q")
if rc != 0 or "bench66960498.local/scratch/old:1" not in out.split():
    print("FAIL: ctr -n k8s.io in the Pod should list the node's images: rc=%d" % rc); sys.exit(1)
rc, out = inpod("/crictl", "-r", "unix://" + s, "images", "-o", "json")
tags = sorted(t for i in json.loads(out)["images"] for t in i["repoTags"]) if rc == 0 else []
if tags != sorted(truth["images"]):
    print("FAIL: crictl in the Pod does not list the images of setup: %s" % tags); sys.exit(1)
cons = json.loads(sh(crictl, "ps", "-a", "-o", "json")[1])["containers"]
if sorted(c["id"] for c in cons) != sorted(truth["containers"].values()) or any(c["state"] != "CONTAINER_RUNNING" for c in cons):
    print("FAIL: the node's containers are not the three of setup, running"); sys.exit(1)
if os.listdir(lib + "/job"):
    print("FAIL: the job's directory is not empty"); sys.exit(1)
print("in the purger's container `ctr images ls` (default namespace) prints nothing and exits 0, `ctr -n k8s.io` and crictl list the node's %d images; the images to purge and to keep are all there, three containers run" % len(tags))
PY
) || fail "$res"
echo "[precondition] PASS: $res"
