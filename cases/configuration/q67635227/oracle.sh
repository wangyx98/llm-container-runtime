#!/bin/bash
set -e

CASE_ID="bench67635227"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's programs (the hub, the node's launcher and mk8sctl) and the account are as setup wrote them..."
sudo sh -c 'cd / && sha256sum -c --quiet "$1/lab.sha"' _ "$STATE_DIR" >/dev/null 2>&1 || fail "the hub, the launcher, mk8sctl or the account was changed"

echo "[oracle] new Pods in two namespaces, with a new build of the image for each, are pulled as the node was left, then after 'mk8sctl restart'..."
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

CASE = "bench67635227"
LIB = "/var/lib/" + CASE
SNAP_DATA, SNAP_COMMON = LIB + "/current", LIB + "/common"
ARGS = SNAP_DATA + "/args"
TEMPLATE, GENERATED = ARGS + "/containerd-template.toml", ARGS + "/containerd.toml"
SOCK = SNAP_COMMON + "/run/containerd.sock"
PIDF = SNAP_COMMON + "/run/containerd.pid"
LOGF = SNAP_COMMON + "/var/log/containerd.log"
CTL = LIB + "/bin/mk8sctl"
RUN = "/run/" + CASE
HUB_DIR, HUB_LOG = RUN + "/hub", RUN + "/hub.log"
STATE = "/tmp/%s/.bench" % CASE
ADDR, REG_PORT, TOK_PORT = "127.67.63.52", 5000, 5001
REPO = "benchlab67635/app"
PAUSE_REF = CASE + ".local/pause:1"
POD_CGROUP = "/%s-pods" % CASE
USER = json.load(open(LIB + "/account.json"))["user"]
NAMESPACES = ("team-a", "team-b")


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


def http(method, url, headers=None):
    req = urllib.request.Request(url, method=method, headers=headers or {})
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def hub_problem():
    """the hub is the process setup started and still applies the rate limit: an anonymous token gets 429 for a GET of a manifest"""
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
    code, _ = http("GET", "http://%s:%d/v2/%s/manifests/v1" % (ADDR, REG_PORT, REPO), {"Authorization": "Bearer " + tok})
    if code != 429:
        return "an anonymous reader is not rate limited any more (GET of a manifest answers %s)" % code
    return None


def node_problem():
    try:
        pid = int(read(PIDF).strip())
        comm = open("/proc/%d/comm" % pid).read().strip()
        cmd = open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode("latin-1").strip()
    except (OSError, ValueError, AttributeError):
        return "there is no containerd of mk8sctl (no pid file: the node was not started with mk8sctl)"
    if comm != "containerd" or cmd != "containerd --config " + GENERATED:
        return "the process %d is not the containerd of mk8sctl (command line: %s)" % (pid, short(cmd, 90))
    return None


def render(text):
    return text.replace("${SNAP_DATA}", SNAP_DATA).replace("${SNAP_COMMON}", SNAP_COMMON)


def wipe_pods():
    for p in crictl("pods", "-q").stdout.split():
        crictl("stopp", p)
        crictl("rmp", p)


def wipe_hub_images():
    """the node must pull: every image of the account is removed from the CRI's store first (the sandbox image stays)"""
    try:
        images = json.loads(crictl("images", "-o", "json").stdout).get("images", [])
    except ValueError:
        return
    for im in images:
        if any(t.startswith("docker.io/benchlab67635/") for t in im.get("repoTags", [])):
            crictl("rmi", im["id"])


def hub_log_size():
    try:
        return os.path.getsize(HUB_LOG)
    except OSError:
        return 0


def hub_rows(offset):
    with open(HUB_LOG, "rb") as f:
        f.seek(offset)
        return [json.loads(ln) for ln in f.read().decode().splitlines() if ln.strip()]


def publish(tag, salt):
    r = run(["python3", STATE + "/hub.py", "publish", HUB_DIR, REPO, tag, STATE + "/app-bin", "app", salt], timeout=60)
    if r.returncode != 0:
        fail("the lab could not publish a new build: " + short(r.stderr))
    return json.loads(r.stdout.strip().splitlines()[-1])


def new_pod(ns, ref, nonce, off):
    """a new host-network Pod in the namespace ns whose container runs ref: crictl run pulls the image first, as the kubelet does (no credentials of any kind are passed)"""
    uid = secrets.token_hex(8)
    name = "app-" + uid[:6]
    logdir = "%s/var/log/pods/%s" % (SNAP_COMMON, uid)
    os.makedirs(logdir, exist_ok=True)
    labels = {"io.kubernetes.pod.name": name, "io.kubernetes.pod.namespace": ns, "io.kubernetes.pod.uid": uid}
    pod = {"metadata": {"name": name, "namespace": ns, "uid": uid, "attempt": 0}, "log_directory": logdir, "labels": labels,
           "linux": {"cgroup_parent": POD_CGROUP, "security_context": {"namespace_options": {"network": 2}}}}
    ctr = {"metadata": {"name": "app"}, "image": {"image": ref}, "args": [nonce], "log_path": "app.log", "labels": dict(labels, **{"io.kubernetes.container.name": "app"}),
           "linux": {"security_context": {"namespace_options": {"network": 2}}}}
    pf, cf = "%s/pod-%s.json" % (STATE, uid[:6]), "%s/ctr-%s.json" % (STATE, uid[:6])
    json.dump(pod, open(pf, "w"))
    json.dump(ctr, open(cf, "w"))
    r = None
    for _ in range(2):
        r = crictl("run", cf, pf, timeout=150)
        if r.returncode == 0 or hub_rows(off):                      # a pull that reached the hub and failed is the answer; a failure before it (the sandbox of a restarted node) is tried once more
            break
        time.sleep(2)
        wipe_pods()
    return r


def judge(phase):
    """returns the first problem as text, or None"""
    msg = hub_problem() or node_problem()
    if msg:
        return msg
    gen, tpl = read(GENERATED), read(TEMPLATE)
    if gen is None or tpl is None:
        return "args/containerd.toml or args/containerd-template.toml is missing"
    if gen != render(tpl):
        return "containerd.toml is not the rendering of containerd-template.toml (it was edited by hand, or the template was edited after the node's last start)"
    for ns in NAMESPACES:
        wipe_pods()
        wipe_hub_images()
        salt, nonce, tag = secrets.token_hex(6), secrets.token_hex(6), "%s-%s" % (ns, secrets.token_hex(3))
        build = publish(tag, salt)
        ref = "docker.io/%s:%s" % (REPO, tag)
        off = hub_log_size()
        r = new_pod(ns, ref, nonce, off)
        rows = hub_rows(off)
        if r.returncode != 0:
            text = errtext(r)
            if "toomanyrequests" in text or any(x["status"] == 429 for x in rows):
                return "the Pod in %s was not created: the pull of %s is refused with the rate-limit error (429): %s" % (ns, ref, text[:160])
            return "the Pod in %s was not created: %s" % (ns, text)
        if image_id(ref) != build["config"]:
            return "the image of the Pod in %s is not the build the lab published (image id %s, expected %s)" % (ns, (image_id(ref) or "none")[:19], build["config"][:19])
        if any(x["status"] == 429 for x in rows):
            return "the hub answered 429 to a request of the pull in %s" % ns
        if any(x["who"] == "rejected" for x in rows):
            return "the token service rejected credentials during the pull in %s" % ns
        if not all(x["ua"].startswith("containerd/") for x in rows):
            return "a request of the pull in %s did not come from containerd (user agents: %s)" % (ns, sorted({x["ua"] for x in rows}))
        if not any(x["srv"] == "token" and x["method"] == "GET" and x["auth"] == "basic" and x["who"] == USER and x["status"] == 200 for x in rows):
            return "the token service was not asked, with the account's credentials, for the pull in %s" % ns
        for what, dg, kind in (("manifest", build["manifest"], "manifests"), ("config blob", build["config"], "blobs"), ("layer blob", build["layer"], "blobs")):
            if not any(x["srv"] == "registry" and x["method"] == "GET" and x["path"].endswith("/%s/%s" % (kind, dg)) and x["status"] == 200 and x["who"] == USER for x in rows):
                return "the hub did not serve the %s %s to the account during the pull in %s" % (what, dg[:19], ns)
        cid = r.stdout.strip().splitlines()[-1]
        out, end = "", time.time() + 20
        while time.time() < end and nonce not in out:
            time.sleep(0.5)
            out = crictl("logs", cid).stdout
        if "%s %s" % (nonce, salt) not in out:
            return "the container in %s does not print the nonce and the salt of the new build: %s" % (ns, short(out, 100))
        pid = 0
        try:
            pid = int(json.loads(crictl("inspect", "-o", "json", cid).stdout)["info"]["pid"])
        except (ValueError, KeyError, TypeError):
            pass
        salt_file = read("/proc/%d/root/salt" % pid) if pid else None
        if (salt_file or "").strip() != salt:
            return "the root of the running container in %s does not hold the salt of the new build" % ns
        print("[verify] %s: Pod in %s ran %s (pulled with the account: token, manifest, config and layer served to %s)" % (phase, ns, ref, USER))
    wipe_pods()
    return None


if not wait_ready(60):
    fail("the node does not answer on its CRI socket (as the solution left it): " + short((read(LOGF) or "")[-300:], 200))
msg = judge("phase A (node as left)")
if msg:
    fail("phase A (node as left): " + msg)
r = run([CTL, "restart"], timeout=150)
if r.returncode != 0:
    fail("'mk8sctl restart' failed: " + short(r.stderr + r.stdout))
if not wait_ready(90):
    fail("after 'mk8sctl restart' the node does not answer: " + short((read(LOGF) or "")[-300:], 200))
msg = judge("phase B (after mk8sctl restart)")
if msg:
    fail("phase B (after mk8sctl restart): " + msg)
print("[verify] ok")
PYEOF
) && RC=0 || RC=$?
echo "$OUT" | tail -12
[ "$RC" = 0 ] || fail "see above"

echo "[oracle] ALL CHECKS PASSED: new Pods in both namespaces are pulled with the account from the node's own configuration, as left and after a restart of the node."
