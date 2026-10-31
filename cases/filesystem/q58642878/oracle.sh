#!/bin/bash
# Oracle: nothing is taken from what the solution says. The node must run (the lab's k3s binary, one containerd of a k3s). Then, seen from the HOST: the file of containerd's metadata database that the running containerd
# has OPEN, with the content store and the snapshot directory next to it, is on the lab's external disk (device of its loop mount; the loop device is the lab's file). The seed image (digest of setup) and the seed
# Pod (uid of setup, still running, still printing its salt) are there. A NEW image (random salt, imported now with the lab's `k3s ctr images import`) has its layer blob and its unpacked layer (the file /salt) on the
# disk, and a Pod made from it (offline, imagePullPolicy Never) runs the image of that digest and prints that salt. Then the node is restarted with its unit (`k3sctl restart`): containerd's open root is again on the
# disk, the seed and the new image are there, both Pods (same uids) run again and print their salts. A generated config.toml edited by hand does not survive that restart, so it cannot pass.
CASE_ID="bench58642878"
LIB="/var/lib/$CASE_ID"
DISK="/mnt/$CASE_ID-disk"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/ready" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a program of the lab (k3s, its wrapper, k3sctl) changed"
sudo "$LIB/bin/k3sctl" status >/dev/null 2>&1 || fail "the node does not run (it must run when the task is done)"
sudo python3 - "$LIB" "$DISK" "$STATE_DIR" 2>&1 <<'PY'
import glob, json, os, subprocess, sys, time

lib, disk, state = sys.argv[1:4]
truth = json.load(open(state + "/truth.json"))
k3s = lib + "/bin/k3s"
ds = truth["disk_dev"]


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True, timeout=240)
    return r.returncode, (r.stdout + r.stderr).strip()


def kget(*a):
    return sh(k3s, "kubectl", *a)[1]


def metas():
    found = []
    for p in subprocess.run(["pgrep", "-x", "containerd"], capture_output=True, text=True).stdout.split():
        try:
            if "/k3s/data/" not in os.readlink("/proc/%s/exe" % p):    # k3s' own containerd runs the tools k3s unpacked
                continue
            for fd in os.listdir("/proc/%s/fd" % p):
                t = os.readlink("/proc/%s/fd/%s" % (p, fd))
                if t.endswith("/io.containerd.metadata.v1.bolt/meta.db"):
                    found.append(t)
        except OSError:
            pass
    return found


def check_root(when):
    m = metas()
    if len(m) != 1:
        fail("%s: expected one containerd of a k3s with an open metadata db, found %s" % (when, m))
    root = os.path.dirname(os.path.dirname(m[0]))
    for sub in ("io.containerd.metadata.v1.bolt/meta.db", "io.containerd.content.v1.content/blobs", "io.containerd.snapshotter.v1.overlayfs/snapshots"):
        try:
            d = os.stat(root + "/" + sub).st_dev
        except OSError as e:
            fail("%s: containerd's root %s has no %s: %s" % (when, root, sub, e))
        if d != ds:
            fail("%s: containerd's %s (root %s) is on device %s, not on the external disk (%s)" % (when, sub, root, d, ds))
    src = sh("findmnt", "-n", "-o", "SOURCE", disk)[1]
    back = sh("losetup", "-nO", "BACK-FILE", src)[1]
    if not os.path.ismount(disk) or os.path.realpath(back) != os.path.realpath(truth["disk_img"]):
        fail("%s: the external disk is not the lab's loop file mounted at %s" % (when, disk))
    return root


def wait_pod(name, uid, salt, when, timeout=90):
    end = time.time() + timeout
    last = ""
    while time.time() < end:
        out = kget("get", "pod", name, "-o", "jsonpath={.metadata.uid} {.status.phase} {.status.containerStatuses[0].ready}")
        last = out
        if out == uid + " Running true":
            log = kget("logs", name)
            if log == "salt=" + salt:
                return
            last = out + " log=" + log[:80]
        time.sleep(3)
    fail("%s: the Pod %s is not (same uid, Running, ready, printing its salt) in %ds: %s" % (when, name, timeout, last))


def images_ok(refs, when):
    out = sh(k3s, "ctr", "images", "ls")[1]
    for ref, digest in refs:
        if ref not in out or digest not in out:
            fail("%s: the image %s (%s) is not in containerd: %s" % (when, ref, digest[:19], out[:300]))


rc, cfg = sh("cat", lib + "/etc/config.yaml")
root = check_root("before the new import")
wait_pod("b58642878-seed", truth["seed_pod_uid"], truth["seed_salt"], "before the new import")
images_ok([("bench.local/seed:1", truth["seed_manifest"])], "before the new import")

# a NEW image, imported now
salt = os.urandom(10).hex()
ref = "bench.local/new%s:1" % os.urandom(3).hex()
tar = state + "/new.tar"
rc, man = sh("python3", state + "/mkimg.py", tar, ref, "app", state + "/app", salt)
rc, o = sh(k3s, "ctr", "images", "import", tar)
if rc != 0:
    fail("the import of the new image failed: " + o[-200:])
os.remove(tar)
rc, mj = sh(k3s, "ctr", "content", "get", man)
mani = json.loads(mj)
layer, cfgd = mani["layers"][0]["digest"].split(":")[1], mani["config"]["digest"]
root = check_root("after the new import")
blob = root + "/io.containerd.content.v1.content/blobs/sha256/" + layer
if not os.path.exists(blob) or os.stat(blob).st_dev != ds:
    fail("the new image's layer blob is not on the external disk (%s)" % blob)
snaps = [p for p in glob.glob(root + "/io.containerd.snapshotter.v1.overlayfs/snapshots/*/fs/salt") if open(p).read() == salt]
if len(snaps) != 1 or os.stat(snaps[0]).st_dev != ds:
    fail("the new image's unpacked layer (the file /salt with its salt) is not on the external disk: %s" % snaps)
pod = "b58642878-new" + os.urandom(3).hex()
manifest = ("apiVersion: v1\nkind: Pod\nmetadata: {name: %s, namespace: default}\nspec:\n  hostNetwork: true\n  terminationGracePeriodSeconds: 1\n  containers:\n"
            "  - {name: main, image: %s, imagePullPolicy: Never}\n" % (pod, ref))
open(state + "/new-pod.yaml", "w").write(manifest)
rc, o = sh(k3s, "kubectl", "apply", "-f", state + "/new-pod.yaml")
if rc != 0:
    fail("could not create the Pod of the new image: " + o[-200:])
for _ in range(40):
    uid = kget("get", "pod", pod, "-o", "jsonpath={.metadata.uid}")
    if uid:
        break
    time.sleep(1)
wait_pod(pod, uid, salt, "the Pod of the new image")
iid = kget("get", "pod", pod, "-o", "jsonpath={.status.containerStatuses[0].imageID}")
if cfgd not in iid and man not in iid:
    fail("the new Pod runs the image %s, not the one imported (config %s, manifest %s)" % (iid, cfgd[:19], man[:19]))

# the node's own restart: nothing but the unit's files and what the solution put on disk can carry the root over it
rc, o = sh(lib + "/bin/k3sctl", "restart")
if rc != 0:
    fail("the node does not start again with its unit: " + o[-300:])
root2 = check_root("after the restart")
if os.path.realpath(root2) != os.path.realpath(root):
    fail("after the restart containerd's root is another one: %s (was %s)" % (root2, root))
images_ok([("bench.local/seed:1", truth["seed_manifest"]), (ref, man)], "after the restart")
wait_pod("b58642878-seed", truth["seed_pod_uid"], truth["seed_salt"], "after the restart", 120)
wait_pod(pod, uid, salt, "after the restart", 120)
print("containerd's open metadata db, content store and snapshots are on the lab's external disk (%s), before and after the node's restart; the seed image and Pod (same uid, %s) survived the move; an image imported now has its layer blob and unpacked layer on the disk, its Pod runs that image and prints its salt, and still does after the restart" % (root, truth["seed_salt"]))
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
