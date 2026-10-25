#!/bin/bash
# Oracle: nothing is taken from what the solution says; the node's own runtime and file system are asked. (1) Same containerd process, same programs; containerd's root is still the loop-backed file system of setup
# (same device, same backing file: not replaced, not moved). (2) The workload's Pod and container are the ones of setup, running since the same moment, its data file has the same hash. (3) The images the node
# must keep are there with their ids: the one in use (app/web), the sandbox image and the protected keep/tools; every image still listed is complete (ctr images check: nobody removed content by hand) and a container
# can still be made from it. (4) The file system has at least 90 MB free (polled for up to 40 s: removals are collected by containerd's garbage collection) and the workload writes 60 MB of new random data into its
# root file system and reads it back.
CASE_ID="bench65357072"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

[ "$(sudo cat "$STATE_DIR/lab.sha" 2>/dev/null | wc -c)" -gt 0 ] || fail "the lab is not set up"
sudo python3 - "$LIB" "$RUN" "$STATE_DIR" <<'PY'
import hashlib, json, os, subprocess, sys, tempfile, time, uuid

lib, run, state = sys.argv[1:4]
crictl, ctr = lib + "/bin/crictl", lib + "/bin/ctr"
truth = json.load(open(state + "/truth.json"))
w = truth["workload"]
root = lib + "/containerd"
pre = "bench65357072.local/"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def sh(*a, timeout=60):
    r = subprocess.run(a, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


if subprocess.run(["sh", "-c", "cd / && sha256sum -c --quiet '%s/lab.sha'" % state], capture_output=True).returncode != 0:
    fail("a program or the configuration of the node changed")
try:
    if open("/proc/%d/comm" % truth["containerd_pid"]).read().strip() != "containerd":
        raise OSError
except OSError:
    fail("the node's containerd is not the process of setup (restarted or replaced)")
mounted = [l for l in open("/proc/self/mountinfo") if l.split()[4] == root]
if not mounted or os.stat(root).st_dev != truth["mount_dev"] or os.stat(lib + "/containerd.img").st_ino != truth["img_ino"] or "/dev/loop" not in mounted[-1].split(" - ")[1]:
    fail("containerd's root is not the loop-backed file system of setup any more (another device, another backing file, or not mounted)")

rc, o = sh(crictl, "inspect", w["container"])
if rc != 0:
    fail("the workload's container is gone")
c = json.loads(o)
if c["status"]["state"] != "CONTAINER_RUNNING" or c["status"]["startedAt"] != w["started"]:
    fail("the workload's container is not the running one of setup (state %s)" % c["status"]["state"])
pid = c["info"]["pid"]
data = "/proc/%d/root/tmp/work-data.bin" % pid
try:
    if hashlib.sha256(open(data, "rb").read()).hexdigest() != w["data_sha"]:
        fail("the workload's data file changed")
except OSError as e:
    fail("the workload's data file cannot be read: %s" % e)

imgs = {t: i["id"] for i in json.loads(sh(crictl, "images", "-o", "json")[1])["images"] for t in i["repoTags"]}
for t in ("app/web:1", "pause:1", "keep/tools:1"):
    if imgs.get(pre + t) != truth["images"][pre + t]:
        fail("the image %s is missing or changed: it must stay" % t)
import re
blobs = set(sh(ctr, "content", "ls", "-q")[1].split())
bad = [l.split()[0] for l in sh(ctr, "images", "check")[1].splitlines()[1:] if not re.search(r"\scomplete \(", l)]
if bad:
    fail("images that are not complete (content removed by hand?): %s" % [b.replace(pre, "")[:30] for b in bad])
pod_name = "chk-" + uuid.uuid4().hex[:6]
for t in sorted(imgs):
    n = pod_name
    with tempfile.TemporaryDirectory() as d:
        json.dump({"metadata": {"name": n, "namespace": "default", "uid": str(uuid.uuid4()), "attempt": 0}, "log_directory": run + "/log/" + n,
                   "linux": {"cgroup_parent": "/bench65357072", "security_context": {"namespace_options": {"network": 2}}}}, open(d + "/pod.json", "w"))
        json.dump({"metadata": {"name": "t"}, "image": {"image": t}, "log_path": "t.log", "args": [], "linux": {"security_context": {"namespace_options": {"network": 2}}}}, open(d + "/ctr.json", "w"))
        os.makedirs(run + "/log/" + n, exist_ok=True)
        ok, same = False, True
        rc, p = sh(crictl, "runp", d + "/pod.json")
        if rc == 0:
            rc, cc = sh(crictl, "create", p, d + "/ctr.json", d + "/pod.json")
            if rc == 0:
                ok = sh(crictl, "start", cc)[0] == 0
            if ok and t in truth["blob_sha"]:      # the layer's file in the container is the one that was imported
                try:
                    f = "/proc/%d/root/blob.bin" % json.loads(sh(crictl, "inspect", cc)[1])["info"]["pid"]
                    same = hashlib.sha256(open(f, "rb").read()).hexdigest() == truth["blob_sha"][t]
                except OSError:
                    same = False
            sh(crictl, "stopp", p); sh(crictl, "rmp", p)
    if not ok and not t.endswith("pause:1"):
        fail("a container cannot be made from the image %s (its layers or snapshot are damaged)" % t.replace(pre, ""))
    if not same:
        fail("the layer file of the image %s in a new container is missing or damaged (snapshot files removed by hand?)" % t.replace(pre, ""))
    if any(l not in blobs for l in truth["layers"].get(t, [])):
        fail("the content store has lost a layer of the image %s (blobs removed by hand?)" % t.replace(pre, ""))

deadline, free = time.time() + 40, 0
while True:
    st = os.statvfs(root)
    free = st.f_bavail * st.f_frsize // 1048576
    if free >= 90 or time.time() > deadline:
        break
    time.sleep(2)
if free < 90:
    fail("the file system under containerd's root has %d MB free, at least 90 MB are needed" % free)
new = "/proc/%d/root/tmp/new-data.bin" % pid
sha = hashlib.sha256()
try:
    with open(new, "wb") as h:
        for _ in range(60):
            b = os.urandom(1048576)
            sha.update(b); h.write(b)
        h.flush(); os.fsync(h.fileno())
    if hashlib.sha256(open(new, "rb").read()).hexdigest() != sha.hexdigest():
        fail("the 60 MB the workload wrote do not read back")
except OSError as e:
    fail("the workload cannot write 60 MB into its root file system: %s" % e)
finally:
    if os.path.exists(new):
        os.remove(new)
print("same containerd, same loop-backed file system; the workload (same container, same data) writes 60 MB; %d MB free; app/web, pause and keep/tools kept, every image complete and startable" % free)
PY
rc=$?
[ $rc -eq 0 ] || exit 1
echo "[oracle] PASS"
