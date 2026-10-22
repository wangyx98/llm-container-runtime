#!/bin/bash
set -e

CASE_ID="bench64935442"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's programs, configuration and account (the hub, the hosts file of docker.io, the containerd and k3s configuration, the control scripts) are as setup wrote them..."
sudo sh -c 'cd / && sha256sum -c --quiet "$1/lab.sha"' _ "$STATE_DIR" >/dev/null 2>&1 || fail "a program, a configuration file or the account of the lab was changed"

echo "[oracle] the image is removed from the node and a new build is published under the same tag; a Pod without a pull secret in another namespace is still refused; then blaw is scaled up again..."
OUT=$(sudo python3 - <<'PYEOF' 2>&1
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request

CASE = "bench64935442"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
CTL = LIB + "/bin"
KUBECTL = CTL + "/kubectl"
K3S = LIB + "/libexec/k3s"
SOCK = RUN + "/containerd.sock"
HUB_DIR, HUB_LOG = RUN + "/hub", RUN + "/hub.log"
STATE = "/tmp/%s/.bench" % CASE
ADDR, REG_PORT, TOK_PORT = "127.64.93.54", 5000, 5001
REPO, TAG = "benchlab64935/blaw-service", "v0.3.10"
IMAGE = "%s:%s" % (REPO, TAG)
NODE = CASE + "-node"
OTHER_NS = "bench-other"
USER = json.load(open(LIB + "/account.json"))["user"]


def fail(msg):
    print("[verify] FAIL: " + msg)
    sys.exit(1)


def short(text, n=200):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 3] + "..."


def run(argv, timeout=120, stdin=None):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", input=stdin,
                          stdin=None if stdin is not None else subprocess.DEVNULL)


def kc(*args, timeout=120, stdin=None):
    return run([KUBECTL] + list(args), timeout=timeout, stdin=stdin)


def kjson(*args):
    r = kc(*args, "-o", "json")
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def crict(*args):
    return run([K3S, "crictl", "-r", "unix://" + SOCK, "-i", "unix://" + SOCK, "--timeout", "60s"] + list(args))


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def http(method, url, headers=None):
    req = urllib.request.Request(url, method=method, headers=headers or {})
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def hub_problem():
    """the hub is the process setup started and is still a private repository: an anonymous token is given, and it opens nothing"""
    pid = int(read(STATE + "/hub.pid"))
    try:
        start = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except OSError:
        return "the hub is not running"
    if start != read(STATE + "/hub.start").strip():
        return "the hub is not the process setup started (it was stopped or replaced)"
    code, body = http("GET", "http://%s:%d/token?service=x&scope=repository:%s:pull" % (ADDR, TOK_PORT, REPO))
    tok = json.loads(body).get("token") if code == 200 else None
    if not tok:
        return "the token service does not give an anonymous token (%s)" % code
    for method, path in (("HEAD", "manifests/" + TAG), ("GET", "manifests/" + TAG)):
        code, _ = http(method, "http://%s:%d/v2/%s/%s" % (ADDR, REG_PORT, REPO, path), {"Authorization": "Bearer " + tok})
        if code != 401:
            return "the repository is not private any more (%s of a manifest with an anonymous token answers %s)" % (method, code)
    return None


def lab_problem():
    for name in ("containerdctl", "k3sctl"):
        if run([CTL + "/" + name, "status"]).returncode != 0:
            return "%s reports that %s is not running" % (name, name[:-3])
    r = kc("get", "node", NODE, "-o", "jsonpath={.status.conditions[?(@.type==\"Ready\")].status}")
    if r.stdout.strip() != "True":
        return "the node %s is not Ready" % NODE
    return None


def hub_log_size():
    try:
        return os.path.getsize(HUB_LOG)
    except OSError:
        return 0


def hub_rows(offset):
    with open(HUB_LOG, "rb") as f:
        f.seek(offset)
        return [json.loads(ln) for ln in f.read().decode().splitlines() if ln.strip()]


def pods(ns, selector=None):
    args = ["get", "pods", "-n", ns] + (["-l", selector] if selector else [])
    j = kjson(*args)
    return (j or {}).get("items", [])


def waiting(pod):
    cs = (pod.get("status", {}).get("containerStatuses") or [{}])[0]
    return cs.get("state", {}).get("waiting", {})


def wait_gone(ns, selector=None, timeout=90):
    end = time.time() + timeout
    while time.time() < end:
        if not pods(ns, selector):
            return True
        time.sleep(1)
    return False


def wipe_images():
    """the node must pull: every image of the repository is removed from the node's store"""
    r = crict("images", "-o", "json")
    try:
        images = json.loads(r.stdout).get("images", [])
    except ValueError:
        fail("could not list the images of the node: " + short(r.stderr))
    for im in images:
        if any("/" + REPO + ":" in t or "/" + REPO + "@" in t for t in im.get("repoTags", []) + im.get("repoDigests", [])):
            crict("rmi", im["id"])
    r = crict("images", "-o", "json")
    for im in json.loads(r.stdout).get("images", []):
        if any(REPO in t for t in im.get("repoTags", []) + im.get("repoDigests", [])):
            fail("the image %s could not be removed from the node" % im["id"][:19])


def publish(salt):
    r = run(["python3", STATE + "/hub.py", "publish", HUB_DIR, REPO, TAG, STATE + "/app-bin", "app", salt], timeout=60)
    if r.returncode != 0:
        fail("the lab could not publish a new build: " + short(r.stderr))
    return json.loads(r.stdout.strip().splitlines()[-1])


def failing_message(pod):
    """why the Pod does not start: the last pull error among its events, else the waiting reason"""
    ev = kc("get", "events", "-n", pod["metadata"]["namespace"], "--field-selector", "involvedObject.name=" + pod["metadata"]["name"],
            "-o", "jsonpath={range .items[*]}{.message}{\"\\n\"}{end}").stdout.splitlines()
    pulls = [m for m in ev if "Failed to pull image" in m]
    if pulls:
        return short(pulls[-1].split("failed to resolve image: ")[-1], 220)
    w = waiting(pod)
    return short(w.get("message") or w.get("reason") or (ev[-1] if ev else ""), 220)


msg = hub_problem() or lab_problem()
if msg:
    fail(msg)

d = kjson("get", "deployment", "blaw", "-n", "default")
if not d:
    fail("the Deployment blaw does not exist in the namespace default")
cs = d["spec"]["template"]["spec"]["containers"]
if len(cs) != 1 or cs[0]["image"] != IMAGE:
    fail("the Deployment blaw must have one container with the image %s (it has %s)" % (IMAGE, [c["image"] for c in cs]))
if d["spec"].get("replicas") != 1:
    fail("the Deployment blaw must have 1 replica (it has %s)" % d["spec"].get("replicas"))

# 1. nothing of blaw runs, the image is not in the node, a new build of the same tag is in the hub
r = kc("scale", "deployment", "blaw", "-n", "default", "--replicas=0")
if r.returncode != 0:
    fail("could not scale blaw down: " + short(r.stderr))
if not wait_gone("default", "app=blaw"):
    fail("the Pods of blaw did not stop")
wipe_images()
salt = secrets.token_hex(6)
build = publish(salt)
print("[verify] the node has no copy of the image; the hub holds a new build of %s (manifest %s)" % (IMAGE, build["manifest"][:19]))

# 2. a Pod without a pull secret in another namespace must not be able to pull it (the node must not hold credentials of its own)
kc("delete", "namespace", OTHER_NS, "--ignore-not-found", "--wait=true", "--timeout=90s")
r = kc("create", "namespace", OTHER_NS)
if r.returncode != 0:
    fail("could not create the namespace %s: %s" % (OTHER_NS, short(r.stderr)))
end = time.time() + 30
while time.time() < end and kc("get", "serviceaccount", "default", "-n", OTHER_NS).returncode != 0:
    time.sleep(1)
off_other = hub_log_size()
manifest = {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "nosecret", "namespace": OTHER_NS},
            "spec": {"containers": [{"name": "transcribe-service", "image": IMAGE}]}}
r = kc("apply", "-f", "-", stdin=json.dumps(manifest))
if r.returncode != 0:
    fail("could not create the control Pod: " + short(r.stderr))
seen, end = "", time.time() + 60
while time.time() < end:
    ps = pods(OTHER_NS)
    if ps:
        if ps[0].get("status", {}).get("containerStatuses", [{}])[0].get("state", {}).get("running"):
            fail("a Pod without a pull secret in the namespace %s pulled and started the private image: the node itself must not hold credentials for the repository" % OTHER_NS)
        seen = waiting(ps[0]).get("reason", "")
        if seen in ("ErrImagePull", "ImagePullBackOff"):
            break
    time.sleep(1)
if seen not in ("ErrImagePull", "ImagePullBackOff"):
    fail("the control Pod in %s neither started nor failed to pull in 60 s (state: %s)" % (OTHER_NS, seen or "none"))
rows = hub_rows(off_other)
if any(x["who"] == USER for x in rows) or not any(x["srv"] == "registry" and x["status"] == 401 and x["who"] == "anonymous" for x in rows):
    fail("the control Pod in %s was not refused as an anonymous reader (hub log: %s)" % (OTHER_NS, short(json.dumps(rows[-3:]), 200)))
kc("delete", "namespace", OTHER_NS, "--wait=true", "--timeout=90s")
print("[verify] a Pod without a pull secret in another namespace is refused as an anonymous reader (%s)" % seen)

# 3. blaw is scaled up: a new Pod must pull the new build with the account
off = hub_log_size()
r = kc("scale", "deployment", "blaw", "-n", "default", "--replicas=1")
if r.returncode != 0:
    fail("could not scale blaw up: " + short(r.stderr))
pod, end = None, time.time() + 75
last = ""
while time.time() < end:
    for p in pods("default", "app=blaw"):
        st = p.get("status", {}).get("containerStatuses") or [{}]
        if p["metadata"].get("deletionTimestamp"):
            continue
        last = failing_message(p) if waiting(p) else last
        if st[0].get("state", {}).get("running") and st[0].get("ready"):
            pod = p
    if pod:
        break
    time.sleep(1.5)
if not pod:
    fail("the Pod of blaw did not become Running and Ready in 75 s%s" % ((": " + last) if last else ""))
name = pod["metadata"]["name"]
owner = (pod["metadata"].get("ownerReferences") or [{}])[0]
if owner.get("kind") != "ReplicaSet" or not owner.get("name", "").startswith("blaw-"):
    fail("the Running Pod %s does not belong to the Deployment blaw" % name)
cst = pod["status"]["containerStatuses"][0]
if not cst.get("imageID", "").endswith(build["manifest"]):
    fail("the Pod runs another image than the new build (imageID %s, manifest %s)" % (short(cst.get("imageID"), 120), build["manifest"][:19]))
logs = kc("logs", name, "-n", "default").stdout
if "SALT %s" % salt not in logs.split("\n"):
    fail("the container does not print the salt of the new build: " + short(logs, 100))
rows = hub_rows(off)
if not all(x["ua"].startswith("containerd/") for x in rows):
    fail("a request in the hub's log did not come from containerd (user agents: %s)" % sorted({x["ua"] for x in rows}))
if any(x["who"] == "rejected" for x in rows):
    fail("the token service rejected credentials during the pull")
if not any(x["srv"] == "token" and x["method"] == "GET" and x["auth"] == "basic" and x["who"] == USER and x["status"] == 200 for x in rows):
    fail("the token service was not asked, with the account's credentials, for the pull")
for what, dg, kind in (("manifest", build["manifest"], "manifests"), ("config blob", build["config"], "blobs"), ("layer blob", build["layer"], "blobs")):
    if not any(x["srv"] == "registry" and x["method"] == "GET" and x["path"].endswith("/%s/%s" % (kind, dg)) and x["status"] == 200 and x["who"] == USER for x in rows):
        fail("the hub did not serve the %s %s to the account" % (what, dg[:19]))
print("[verify] Pod %s runs the new build (imageID ends with the manifest %s), printed SALT %s; the hub served the manifest and both blobs to %s" % (name, build["manifest"][:19], salt, USER))
print("[verify] ok")
PYEOF
) && RC=0 || RC=$?
echo "$OUT" | tail -12
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: with the Secret named by its Pods, blaw pulls the new build of the private image as the account; a Pod without the Secret is still refused."
