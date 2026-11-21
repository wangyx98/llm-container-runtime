#!/bin/bash
set -e

CASE_ID="bench76134722"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"
WL="$LIB_BASE/workload"

fail() { echo "  -> FAIL: $*"; exit 1; }

lab_ok() {   # the node as setup left it: files, the containerd process, the pod and its two containers
    sudo env STATE_DIR="$STATE_DIR" RUN_BASE="$RUN_BASE" CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF' || exit 1
import hashlib, json, os, subprocess, sys
E = os.environ
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
for f, h in st["files"].items():
    try: now = hashlib.sha256(open(f, "rb").read()).hexdigest()
    except OSError: fail("%s is gone (the node's files, the keep list and the workload's definitions stay as setup made them)" % f)
    if now != h: fail("%s was changed (the node's files, the keep list and the workload's definitions stay as setup made them)" % f)
try:
    pid = int(open(E["RUN_BASE"] + "/containerd.pid").read())
    comm = open("/proc/%d/comm" % pid).read().strip()
    stat = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
    if stat[0] in ("Z", "X"): raise OSError("dead")
except Exception: fail("the node's containerd is not running")
if comm != "containerd" or pid != st["containerd"]["pid"] or stat[19] != st["containerd"]["start"]: fail("the node's containerd was restarted or replaced (it runs on as setup started it)")
def crictl(*a):
    return json.loads(subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CTD_SOCK"], "--image-endpoint", "unix://" + E["CTD_SOCK"]] + list(a) + ["-o", "json"], capture_output=True, text=True).stdout or "{}")
pods = crictl("pods").get("items", [])
if [p["id"] for p in pods] != [st["sandbox"]] or pods[0]["state"] != "SANDBOX_READY": fail("the node's pods are not the one recorded, Ready (the workload is not to be recreated; no pod is to be left behind)")
cs = {c["metadata"]["name"]: c for c in crictl("ps", "-a").get("containers", [])}
if sorted(cs) != ["api", "web"] or any(cs[n]["id"] != st["ctrs"][n] or cs[n]["state"] != "CONTAINER_RUNNING" for n in cs): fail("the containers of the workload are not the two recorded, running (not to be recreated or restarted; none is to be left behind)")
PYEOF
}

echo "[oracle] checking the node is as the setup left it (files, keep list and workload definitions unchanged; the same containerd; the same pod with its two running containers)..."
lab_ok
echo "  -> OK"

echo "[oracle] the images the CRI lists: every idle image with the dev- tag that is not on the keep list is gone (the image with its blobs), the shared image lost only its dev- name, everything else is as it was..."
sudo env STATE_DIR="$STATE_DIR" CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF' || exit 1
import json, os, subprocess, sys, time
E = os.environ
S = E["CTD_SOCK"]
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
def run(*a):
    return subprocess.run(list(a), capture_output=True, text=True)
def crictl(*a):
    return json.loads(run("crictl", "--runtime-endpoint", "unix://" + S, "--image-endpoint", "unix://" + S, *a, "-o", "json").stdout or "{}")
def ctr(*a, ns="k8s.io"):
    return run("ctr", "-a", S, "-n", ns, *a)
images = {i["id"]: i for i in crictl("images").get("images", [])}
def why(n):
    return ", it is in use" if n in st["used"] else (", it is the sandbox image" if n == st["pause"] else (", it is on the keep list" if n in keep_list else ""))
keep_list = {l.strip() for l in open("/var/lib/bench76134722/keep-images.txt") if l.strip() and not l.startswith("#")}
tset = set(st["target"])
for img in st["images"]:      # first what must stay
    names = set(img["names"])
    if names & tset: continue
    have = set(images.get(img["id"], {}).get("repoTags", []))
    if have != names: fail("%s was removed or changed: its names are now %s (it must stay%s)" % (img["names"][0], sorted(have) or "none", why(img["names"][0])))
gone = []
for img in st["images"]:      # then what must go
    names = set(img["names"])
    if names <= tset:
        if img["id"] in images:
            fail("the idle image %s (with the dev- tag, not on the keep list) is still on the node%s" % (img["names"][0], " (its names are removed but the image stays untagged, with its blobs)" if not images[img["id"]]["repoTags"] else ""))
        gone.extend(img["names"])
    elif names & tset:
        have = set(images.get(img["id"], {}).get("repoTags", []))
        left = names - tset
        if have != left: fail("the image that carries %s now has the names %s, expected %s (only the dev- name goes; the image and its other name stay)" % (sorted(names), sorted(have) or "none", sorted(left)))
        gone.extend(names & tset)
untagged = [i["id"][:19] for i in images.values() if not i["repoTags"]]
if untagged: fail("an image is left on the node without any name (%s): removing only its name leaves the image and its blobs in the store" % ", ".join(untagged))
known = {i["id"] for i in st["images"]}
extra = [i[:19] for i in images if i not in known]
if extra: fail("the node has images that were not there before: %s" % extra)
# the blobs of the removed images are reclaimed (the garbage collector of containerd runs after the removal), the blobs of the others are all there
own_gone = [b for img in st["images"] if set(img["names"]) <= set(st["target"]) for b in img["own_blobs"]]
deadline = time.time() + 45
while True:
    blobs = set(ctr("content", "ls", "-q").stdout.split())
    left = [b for b in own_gone if b in blobs]
    if not left or time.time() > deadline: break
    time.sleep(1)
if left: fail("%d blobs of the removed images are still in the content store after 45 s (space not reclaimed)" % len(left))
for img in st["images"]:
    if set(img["names"]) <= set(st["target"]): continue
    for b in img["own_blobs"] + [st["base"]]:
        if b not in blobs: fail("a blob of %s is missing from the content store (an image that stays was damaged)" % img["names"][0])
other = ctr("images", "ls", "-q", ns="bench-other").stdout.split()
if st["other"][0]["names"][0] not in other: fail("the image %s of the namespace bench-other was removed (only the images of the CRI, the namespace k8s.io, are meant)" % st["other"][0]["names"][0])
print("  -> OK: %d names removed with their images or alone (%d images and their blobs gone), %d names unchanged, no untagged leftover, the image of the other namespace is still there" % (len(gone), sum(1 for img in st["images"] if set(img["names"]) <= set(st["target"])), len(st["keep"])))
PYEOF

echo "[oracle] the node still works with what is left: a new pod (it needs the sandbox image) and a new container from every image that stays..."
sudo env STATE_DIR="$STATE_DIR" CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF' || exit 1
import json, os, subprocess, sys, time
E = os.environ
S = E["CTD_SOCK"]
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
def cri(*a):
    return subprocess.run(["crictl", "--runtime-endpoint", "unix://" + S, "--image-endpoint", "unix://" + S] + list(a), capture_output=True, text=True, timeout=60)
uid = "bench76134722-oracle-%d" % int(time.time())
pod = {"metadata": {"name": "oracle-probe", "namespace": "bench", "uid": uid, "attempt": 0}, "log_directory": "/run/bench76134722/logs", "linux": {"security_context": {"namespace_options": {"network": 2}}}}
open("/run/bench76134722/oracle-pod.json", "w").write(json.dumps(pod))
p = cri("runp", "/run/bench76134722/oracle-pod.json")
pid = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ""
if p.returncode != 0 or not pid: fail("a new pod sandbox cannot be made: %s" % (p.stderr.strip().splitlines() or [""])[-1][:200])
try:
    bad = []
    for k, n in enumerate(st["keep"]):
        c = {"metadata": {"name": "c%d" % k}, "image": {"image": n}, "command": ["/bin/sh", "-c", "sleep 30"], "log_path": "oracle-%d.log" % k, "linux": {}}
        open("/run/bench76134722/oracle-c.json", "w").write(json.dumps(c))
        r = cri("create", pid, "/run/bench76134722/oracle-c.json", "/run/bench76134722/oracle-pod.json")
        cid = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
        if r.returncode != 0 or not cid: bad.append("%s (create: %s)" % (n, (r.stderr.strip().splitlines() or [""])[-1][:120])); continue
        s = cri("start", cid)
        if s.returncode != 0: bad.append("%s (start: %s)" % (n, (s.stderr.strip().splitlines() or [""])[-1][:120]))
    time.sleep(1)
    running = json.loads(cri("ps", "-o", "json").stdout or "{}").get("containers", [])
    n_run = sum(1 for c in running if c["podSandboxId"] == pid and c["state"] == "CONTAINER_RUNNING")
    if bad: fail("a container cannot be made from an image that must stay: %s" % "; ".join(bad))
    if n_run != len(st["keep"]): fail("%d of %d new containers run" % (n_run, len(st["keep"])))
    print("  -> OK: a new pod and %d containers, one from every image that stays, run" % n_run)
finally:
    cri("stopp", pid); cri("rmp", "-f", pid)
    for f in ("oracle-pod.json", "oracle-c.json"):
        try: os.unlink("/run/bench76134722/" + f)
        except OSError: pass
PYEOF

echo "[oracle] the node is still as the setup left it after the checks (the oracle's own pod removed)..."
lab_ok
echo "  -> OK"
echo "[oracle] PASS: the idle dev- images that are not on the keep list are gone with their blobs; the keep list, the images in use, the sandbox image, the other tags and the other namespace are untouched; the node runs new pods and containers."
