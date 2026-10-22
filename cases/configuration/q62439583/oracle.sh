#!/bin/bash
set -e

CASE_ID="bench62439583"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's programs (the JFrog stand-in with its upstreams, nodectl) and the accounts are as setup wrote them..."
sudo sh -c 'cd / && sha256sum -c --quiet "$1/lab.sha"' _ "$STATE_DIR" >/dev/null 2>&1 || fail "the JFrog stand-in, nodectl or the accounts file was changed"

echo "[oracle] new builds of the Docker Hub image (pulled as docker.io/... and as k8s.gcr.io/...) and of the Quay image are pulled and run as the node was left, then after 'nodectl restart'..."
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
import base64

CASE = "bench62439583"
LIB = "/var/lib/" + CASE
COMMON = LIB + "/common"
CONFIG = LIB + "/etc/containerd.toml"
SOCK = COMMON + "/run/containerd.sock"
PIDF = COMMON + "/run/containerd.pid"
LOGF = COMMON + "/var/log/containerd.log"
CTL = LIB + "/bin/nodectl"
RUN = "/run/" + CASE
STORE_DOCKER, STORE_QUAY = RUN + "/store-docker-hub", RUN + "/store-quay"
JCR_LOG, UP_LOG = RUN + "/jcr.log", RUN + "/upstream.log"
STATE = "/tmp/%s/.bench" % CASE
ADDR_DOCKER, ADDR_QUAY, PORT = "127.62.43.95", "127.62.43.96", 8082
WEB_REPO, FLANNEL_REPO, FLANNEL_TAG = "benchlab62439/web", "benchlab62439/flannel", "v0.11.0-amd64"
PAUSE_REF = CASE + ".local/pause:1"
POD_CGROUP = "/%s-pods" % CASE
ACCOUNTS = json.load(open(LIB + "/accounts.json"))
# the three pulls: the name of the registry in the reference, the repository, the store the build goes to, the repository of the stand-in that must serve it, the account that must be used
PULLS = (("docker.io", WEB_REPO, STORE_DOCKER, "docker", "ci", "t"),
         ("k8s.gcr.io", WEB_REPO, STORE_DOCKER, "docker", "ci", "t"),
         ("quay.io", FLANNEL_REPO, STORE_QUAY, "quay-remote", "quay-reader", FLANNEL_TAG + "-t"))


def fail(msg):
    print("[verify] FAIL: " + msg)
    sys.exit(1)


def short(text, n=200):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 3] + "..."


def run(argv, timeout=120):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", stdin=subprocess.DEVNULL)


def crictl(*args, timeout=120):
    return run(["crictl", "-r", "unix://" + SOCK, "-i", "unix://" + SOCK, "--timeout", "90s"] + list(args), timeout=timeout)


def errtext(r, n=240):
    lines = [ln for ln in (r.stderr + "\n" + r.stdout).splitlines() if ln.strip() and "level=warning" not in ln]
    text = " ".join(lines)
    m = re.findall(r"desc = (.*)", text)
    return short(m[-1] if m else text, n)


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def image_id(ref):
    try:
        return json.loads(crictl("inspecti", "-o", "json", ref).stdout)["status"]["id"]
    except (ValueError, KeyError):
        return None


def wait_ready(timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(SOCK) and crictl("version").returncode == 0 and image_id(PAUSE_REF):
            return True
        time.sleep(0.5)
    return False


def status(addr, path, account=None):
    h = {}
    if account:
        h["Authorization"] = "Basic " + base64.b64encode(("%s:%s" % (account, ACCOUNTS[account])).encode()).decode()
    req = urllib.request.Request("http://%s:%d%s" % (addr, PORT, path), headers=h)
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except OSError:
        return 0


def jcr_problem():
    """the stand-in is the process setup started and still applies its rules: no credentials 401, ci reads docker and not quay-remote, quay-reader the other way round"""
    pid = int(read(STATE + "/jcr.pid"))
    try:
        start = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except OSError:
        return "the JFrog stand-in is not running"
    if start != read(STATE + "/jcr.start").strip():
        return "the JFrog stand-in is not the process setup started (it was stopped or replaced)"
    web, flannel = "/v2/%s/manifests/v1" % WEB_REPO, "/v2/%s/manifests/%s" % (FLANNEL_REPO, FLANNEL_TAG)
    for what, got, want in (("an anonymous request to docker", status(ADDR_DOCKER, web), 401), ("an anonymous request to quay-remote", status(ADDR_QUAY, flannel), 401),
                            ("ci reading docker", status(ADDR_DOCKER, web, "ci"), 200), ("ci reading quay-remote", status(ADDR_QUAY, flannel, "ci"), 403),
                            ("quay-reader reading quay-remote", status(ADDR_QUAY, flannel, "quay-reader"), 200), ("quay-reader reading docker", status(ADDR_DOCKER, web, "quay-reader"), 403)):
        if got != want:
            return "the stand-in's rules were changed: %s answers %s, not %s" % (what, got, want)
    return None


def node_problem():
    try:
        pid = int(read(PIDF).strip())
        comm = open("/proc/%d/comm" % pid).read().strip()
        cmd = open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode("latin-1").strip()
    except (OSError, ValueError, AttributeError):
        return "there is no containerd of nodectl (no pid file: the node was not started with nodectl)"
    if comm != "containerd" or cmd != "containerd --config " + CONFIG:
        return "the process %d is not the containerd of nodectl (command line: %s)" % (pid, short(cmd, 90))
    return None


def wipe_pods():
    for p in crictl("pods", "-q").stdout.split():
        crictl("stopp", p)
        crictl("rmp", p)


def wipe_images():
    """the node must pull: every image but the sandbox image is removed from the CRI's store first"""
    try:
        images = json.loads(crictl("images", "-o", "json").stdout).get("images", [])
    except ValueError:
        return
    for im in images:
        if PAUSE_REF not in im.get("repoTags", []):
            crictl("rmi", im["id"])


def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def rows(path, offset):
    with open(path, "rb") as f:
        f.seek(offset)
        return [json.loads(ln) for ln in f.read().decode().splitlines() if ln.strip()]


def publish(store, repo, tag, salt):
    r = run(["python3", STATE + "/jcr.py", "publish", store, repo, tag, STATE + "/app-bin", "app", salt], timeout=60)
    if r.returncode != 0:
        fail("the lab could not publish a new build: " + short(r.stderr))
    return json.loads(r.stdout.strip().splitlines()[-1])


def new_pod(ref, nonce, off):
    """a new host-network Pod whose container runs ref: crictl run pulls the image first, as the kubelet does (no credentials of any kind are passed)"""
    uid = secrets.token_hex(8)
    name = "app-" + uid[:6]
    logdir = "%s/var/log/pods/%s" % (COMMON, uid)
    os.makedirs(logdir, exist_ok=True)
    labels = {"io.kubernetes.pod.name": name, "io.kubernetes.pod.namespace": "team-a", "io.kubernetes.pod.uid": uid}
    pod = {"metadata": {"name": name, "namespace": "team-a", "uid": uid, "attempt": 0}, "log_directory": logdir, "labels": labels,
           "linux": {"cgroup_parent": POD_CGROUP, "security_context": {"namespace_options": {"network": 2}}}}
    ctr = {"metadata": {"name": "app"}, "image": {"image": ref}, "args": [nonce], "log_path": "app.log", "labels": dict(labels, **{"io.kubernetes.container.name": "app"}),
           "linux": {"security_context": {"namespace_options": {"network": 2}}}}
    pf, cf = "%s/pod-%s.json" % (STATE, uid[:6]), "%s/ctr-%s.json" % (STATE, uid[:6])
    json.dump(pod, open(pf, "w"))
    json.dump(ctr, open(cf, "w"))
    r = None
    for _ in range(2):
        r = crictl("run", cf, pf, timeout=150)
        if r.returncode == 0 or rows(JCR_LOG, off):                  # a pull that reached the stand-in and failed is the answer; a failure before it (the sandbox of a restarted node) is tried once more
            break
        time.sleep(2)
        wipe_pods()
    return r


def judge(phase):
    """returns the first problem as text, or None"""
    msg = jcr_problem() or node_problem()
    if msg:
        return msg
    if read(CONFIG) is None:
        return "the node's containerd.toml is missing"
    for registry, repo, store, want_repo, want_user, tag_prefix in PULLS:
        wipe_pods()
        wipe_images()
        salt, nonce, tag = secrets.token_hex(6), secrets.token_hex(6), "%s-%s" % (tag_prefix, secrets.token_hex(3))
        build = publish(store, repo, tag, salt)
        ref = "%s/%s:%s" % (registry, repo, tag)
        joff, uoff = size(JCR_LOG), size(UP_LOG)
        r = new_pod(ref, nonce, joff)
        jrows, urows = rows(JCR_LOG, joff), rows(UP_LOG, uoff)
        if r.returncode != 0:
            text = errtext(r)
            bad = sorted({(x["repo"], x["who"], x["status"]) for x in jrows if x["status"] >= 400 and x["status"] != 401})
            return "the Pod for %s was not created: %s (the stand-in answered, by repository, account and status: %s)" % (ref, text, bad or "nothing but 401 or no request")
        if image_id(ref) != build["config"]:
            return "the image of the Pod for %s is not the build the lab published (image id %s, expected %s)" % (ref, (image_id(ref) or "none")[:19], build["config"][:19])
        if not jrows:
            return "the pull of %s did not reach the JFrog stand-in" % ref
        other = sorted({x["repo"] for x in jrows if x["repo"] != want_repo})
        if other:
            return "the pull of %s sent requests to the repository %s; it belongs to %s only" % (ref, other, want_repo)
        if any(x["status"] in (403, 404) or x["status"] >= 500 for x in jrows):
            return "the pull of %s met %s from the stand-in" % (ref, sorted({x["status"] for x in jrows if x["status"] in (403, 404) or x["status"] >= 500}))
        if any(x["who"] not in ("-", want_user) for x in jrows):
            return "the pull of %s was made as %s, not as %s" % (ref, sorted({x["who"] for x in jrows} - {"-"}), want_user)
        if not all(x["ua"].startswith("containerd/") for x in jrows):
            return "a request of the pull of %s did not come from containerd (user agents: %s)" % (ref, sorted({x["ua"] for x in jrows}))
        for what, dg, kind in (("manifest", build["manifest"], "manifests"), ("config blob", build["config"], "blobs"), ("layer blob", build["layer"], "blobs")):
            if not any(x["method"] == "GET" and x["path"].endswith("/%s/%s" % (kind, dg)) and x["status"] == 200 and x["who"] == want_user for x in jrows):
                return "%s did not serve the %s %s to %s during the pull of %s" % (want_repo, what, dg[:19], want_user, ref)
            if not any(x["method"] == "GET" and x["path"].endswith("/%s/%s" % (kind, dg)) and x["status"] == 200 for x in urows):
                return "the upstream did not serve the %s %s to the stand-in during the pull of %s" % (what, dg[:19], ref)
        if not all(x["ua"] == "jcr-lab/1" for x in urows):
            return "the upstream was read by %s during the pull of %s: the node must go through the JFrog stand-in only" % (sorted({x["ua"] for x in urows if x["ua"] != "jcr-lab/1"}), ref)
        cid = r.stdout.strip().splitlines()[-1]
        out, end = "", time.time() + 20
        while time.time() < end and nonce not in out:
            time.sleep(0.5)
            out = crictl("logs", cid).stdout
        if "%s %s" % (nonce, salt) not in out:
            return "the container of %s does not print the nonce and the salt of the new build: %s" % (ref, short(out, 100))
        pid = 0
        try:
            pid = int(json.loads(crictl("inspect", "-o", "json", cid).stdout)["info"]["pid"])
        except (ValueError, KeyError, TypeError):
            pass
        salt_file = read("/proc/%d/root/salt" % pid) if pid else None
        if (salt_file or "").strip() != salt:
            return "the root of the running container of %s does not hold the salt of the new build" % ref
        print("[verify] %s: %s ran (through %s as %s: manifest, config and layer served; the upstream read by the stand-in only)" % (phase, ref, want_repo, want_user))
    wipe_pods()
    return None


if not wait_ready(60):
    fail("the node does not answer on its CRI socket (as the solution left it): " + short((read(LOGF) or "")[-300:], 200))
msg = judge("phase A (node as left)")
if msg:
    fail("phase A (node as left): " + msg)
r = run([CTL, "restart"], timeout=150)
if r.returncode != 0:
    fail("'nodectl restart' failed: " + short(r.stderr + r.stdout))
if not wait_ready(90):
    fail("after 'nodectl restart' the node does not answer: " + short((read(LOGF) or "")[-300:], 200))
msg = judge("phase B (after nodectl restart)")
if msg:
    fail("phase B (after nodectl restart): " + msg)
print("[verify] ok")
PYEOF
) && RC=0 || RC=$?
echo "$OUT" | tail -12
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: the Docker Hub image (as docker.io and as k8s.gcr.io) comes through the repository docker as ci, the Quay image through quay-remote as quay-reader, from the node's own configuration, as left and after a restart of the node."
