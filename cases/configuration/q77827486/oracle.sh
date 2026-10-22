#!/bin/bash
set -e

CASE_ID="bench77827486"
WORK_DIR="/tmp/$CASE_ID"

echo "[oracle] a new image (new digest) is pulled by a new Pod with its own secret, through the original name and the rewrite, authenticated, and runs; the registry still wants credentials; the rewrite, the registry and CRI-O 1.25.2 are untouched..."
OUT=$(sudo python3 - "$WORK_DIR" <<'PYEOF' 2>&1
import base64
import gzip
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

CASE = "bench77827486"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
WORK = sys.argv[1] if len(sys.argv) > 1 else "/tmp/" + CASE
ST = WORK + "/.bench"
CRIO_SOCK = RUN + "/crio.sock"
CRICTL = [LIB + "/bin/crictl", "-r", "unix://" + CRIO_SOCK, "-i", "unix://" + CRIO_SOCK, "--timeout", "120s"]
KUBECTL = [LIB + "/bin/kubectl"]
NODE = CASE
ORIG = "private.registry"       # the name of the images (what the Pods say, what the secret is for)
MIRROR = "mirror.registry"      # where registries.conf sends it
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))      # the registry is local: never through a proxy of the environment


def run(argv, timeout=100, input=None):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", input=input, stdin=None if input is not None else subprocess.DEVNULL)


def short(text, n=200):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 3] + "..."


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def sha_file(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        return None


def wait_for(fn, timeout, step=1.0):
    end = time.time() + timeout
    while True:
        v = fn()
        if v:
            return v
        if time.time() >= end:
            return None
        time.sleep(step)


def truth():
    return json.load(open(ST + "/truth.json"))


def creds():
    return json.load(open(ST + "/creds.json"))


def basic(user, pw):
    return "Basic " + base64.b64encode(("%s:%s" % (user, pw)).encode()).decode()


def reg(method, path, data=None, headers=None, auth="good", host=MIRROR):
    """one request to the registry: auth is 'good', 'bad' (wrong password) or None; returns (status, headers, body)"""
    h = dict(headers or {})
    if auth:
        c = creds()
        h["Authorization"] = basic(c["user"], c["password"] if auth == "good" else "not-the-password")
    r = urllib.request.Request("http://%s%s" % (host, path), data=data, method=method, headers=h)
    try:
        with OPENER.open(r, timeout=20) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def push_image(repo, tag, binary, nonce, cmd):
    """what 'docker push' does, with the plain distribution API: one layer (the program and /nonce), one config, a schema 2 manifest; returns the manifest digest"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        d = open(binary, "rb").read()
        ti = tarfile.TarInfo(os.path.basename(cmd))
        ti.mode, ti.size = 0o755, len(d)
        t.addfile(ti, io.BytesIO(d))
        n = nonce.encode()
        ti = tarfile.TarInfo("nonce")
        ti.size = len(n)
        t.addfile(ti, io.BytesIO(n))
    raw = buf.getvalue()
    layer = gzip.compress(raw)
    dig = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
    cfg = json.dumps({"architecture": {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64"), "os": "linux", "config": {"Cmd": [cmd]},
                      "rootfs": {"type": "layers", "diff_ids": [dig(raw)]}}).encode()
    for blob in (layer, cfg):
        st, hd, _ = reg("POST", "/v2/%s/blobs/uploads/" % repo)
        loc = hd["Location"]
        loc = loc[loc.index("/v2/"):]
        st, hd, body = reg("PUT", loc + ("&" if "?" in loc else "?") + "digest=" + dig(blob), blob, {"Content-Type": "application/octet-stream"})
        if st not in (201, 202):
            raise RuntimeError("push of a blob to %s failed: %d %s" % (repo, st, body[:100]))
    m = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
                    "config": {"mediaType": "application/vnd.docker.container.image.v1+json", "size": len(cfg), "digest": dig(cfg)},
                    "layers": [{"mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip", "size": len(layer), "digest": dig(layer)}]}).encode()
    st, _, body = reg("PUT", "/v2/%s/manifests/%s" % (repo, tag), m, {"Content-Type": "application/vnd.docker.distribution.manifest.v2+json"})
    if st != 201:
        raise RuntimeError("push of the manifest of %s:%s failed: %d %s" % (repo, tag, st, body[:100]))
    return dig(m)


def kv(line):
    return {k: v.strip('"') for k, v in re.findall(r'(\S+?)=("(?:[^"\\]|\\.)*"|\S+)', line)}


def reg_log_size():
    try:
        return os.path.getsize(RUN + "/registry.log")
    except OSError:
        return 0


def reg_log_since(offset):
    """what the registry logged after offset: the authorized requests (host, uri, user, method), the access-log lines (method, path, status, user agent)
    and the set of every host name a request carried"""
    with open(RUN + "/registry.log", "rb") as f:
        f.seek(offset)
        text = f.read().decode("utf-8", "replace")
    authorized, access, hosts = [], [], set()
    for line in text.splitlines():
        if "http.request.host=" in line:
            hosts.add(kv(line).get("http.request.host", ""))
        if 'msg="authorized request"' in line:
            d = kv(line)
            authorized.append({"host": d.get("http.request.host", ""), "uri": d.get("http.request.uri", ""), "user": d.get("auth.user.name", ""), "method": d.get("http.request.method", "")})
        m = re.match(r'^\S+ - \S* \[[^\]]*\] "(\S+) (\S+) HTTP/[\d.]+" (\d+) \d+ "[^"]*" "([^"]*)"', line)
        if m:
            access.append({"method": m.group(1), "path": m.group(2), "status": int(m.group(3)), "ua": m.group(4)})
    return authorized, access, hosts


def pod_json(ns, name):
    r = run(KUBECTL + ["-n", ns, "get", "pod", name, "-o", "json"])
    try:
        return json.loads(r.stdout) if r.returncode == 0 else None
    except ValueError:
        return None


def waiting_message(p):
    try:
        w = p["status"]["containerStatuses"][0]["state"]["waiting"]
        return w.get("reason", ""), w.get("message", "")
    except (KeyError, IndexError, TypeError):
        return "", ""


def pod_events(ns, name):
    r = run(KUBECTL + ["-n", ns, "get", "events", "--field-selector", "involvedObject.name=" + name, "-o", "jsonpath={range .items[*]}{.reason}: {.message}{\"\\n\"}{end}"])
    return r.stdout


def container_id(pod_name, ns):
    r = run(CRICTL + ["ps", "-a", "-q", "--label", "io.kubernetes.pod.name=" + pod_name, "--label", "io.kubernetes.pod.namespace=" + ns])
    return (r.stdout.split() or [None])[0]


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


t, c = truth(), creds()
NS = None
IMAGE = None

# 1. the lab: the registry, the rewrite, CRI-O 1.25.2 and the engineer's secret are what they were
rp = int(read(RUN + "/registry.pid") or 0)
if not rp or not os.path.exists("/proc/%d" % rp) or open("/proc/%d/stat" % rp).read().rsplit(")", 1)[1].split()[19] != t["registry_start"]:
    fail("the registry was stopped, restarted or replaced")
if sha_file(LIB + "/registry/config.yml") != t["registry_config_sha"] or sha_file(LIB + "/registry/htpasswd") != t["htpasswd_sha"]:
    fail("the configuration or the password file of the registry was changed")
if sha_file(RUN + "/registries.conf") != t["registries_conf_sha"]:
    fail("registries.conf was changed: the rewrite private.registry -> mirror.registry has to stay as it is")
if sha_file(LIB + "/opt/crio/crio") != t["crio_sha"] or sha_file(LIB + "/opt/crio/runc") != t["runc_sha"]:
    fail("the crio or the runc program was replaced")
kp = int(read(RUN + "/crio.pid") or 0)
if not kp or not os.path.exists("/proc/%d" % kp):
    fail("CRI-O is not running (crioctl status)")
try:
    exe = os.readlink("/proc/%d/exe" % kp)
    env = open("/proc/%d/environ" % kp, "rb").read().split(b"\0")
except OSError:
    fail("CRI-O's process cannot be inspected")
if exe != LIB + "/opt/crio/crio" or ("CONTAINER_REGISTRIES_CONF=%s/registries.conf" % RUN).encode() not in env:
    fail("CRI-O does not run as the pinned program with the registries.conf of the lab")
if not wait_for(lambda: "RuntimeVersion:  1.25.2" in run(CRICTL + ["version"]).stdout, 90, 2):
    fail("CRI-O 1.25.2 does not answer on its socket")
if not wait_for(lambda: "True" in run(KUBECTL + ["get", "node", NODE, "-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}"]).stdout, 120, 2):
    fail("the node is not Ready")
sec = run(KUBECTL + ["-n", "my-ns", "get", "secret", "registry-secret", "-o", "jsonpath={.data}"]).stdout
if hashlib.sha256(sec.encode()).hexdigest() != t["secret_sha"]:
    fail("the secret my-ns/registry-secret was changed: it has to stay as it is")

# 2. the registry still wants credentials
if reg("GET", "/v2/", auth=None)[0] != 401 or reg("GET", "/v2/", auth="bad")[0] != 401 or reg("GET", "/v2/")[0] != 200:
    fail("the registry does not answer 401 without credentials or with a wrong password, and 200 with the right ones")

try:
    # 3. a new image (a nonce, so a new digest): nobody can have it in the node
    nonce = os.urandom(5).hex()
    tag = "t" + nonce
    push_image("team/app", tag, ST + "/marker", nonce, "/marker")
    if reg("GET", "/v2/team/app/manifests/" + tag, auth=None)[0] != 401:
        fail("the registry gives the manifest of the new image to an anonymous request")
    IMAGE = "%s/team/app:%s" % (ORIG, tag)
    if IMAGE in run(CRICTL + ["images"]).stdout or "team/app" in run(CRICTL + ["images", "-q", IMAGE]).stdout:
        fail("the new image is in the node before its Pod")
    # a new namespace with a secret of its own for private.registry (the one the kubelet looks up by the name of the image), and a Pod like the question's
    NS = "bench-" + nonce
    auth = base64.b64encode(("%s:%s" % (c["user"], c["password"])).encode()).decode()
    dcj = base64.b64encode(json.dumps({"auths": {ORIG: {"username": c["user"], "password": c["password"], "auth": auth}}}).encode()).decode()
    manifest = """apiVersion: v1
kind: Namespace
metadata:
  name: %s
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-secret
  namespace: %s
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: %s
---
apiVersion: v1
kind: Pod
metadata:
  name: pod
  namespace: %s
spec:
  hostNetwork: true
  containers:
    - image: %s
      name: pod
  imagePullSecrets:
    - name: registry-secret
""" % (NS, NS, dcj, NS, IMAGE)
    off = reg_log_size()
    ap = run(KUBECTL + ["apply", "-f", "-"], input=manifest)
    if ap.returncode != 0:
        fail("the Pod of the check could not be created: " + short(ap.stderr))

    # 4. it pulls (the first attempt is the one that counts: a retry after a failure gets 25 s at most) and runs
    state = {"failed_at": None}

    def running():
        p = pod_json(NS, "pod")
        if not p:
            return None
        cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
        if "running" in (cs.get("state") or {}):
            return p
        reason, _ = waiting_message(p)
        if reason in ("ErrImagePull", "ImagePullBackOff") and state["failed_at"] is None:
            state["failed_at"] = time.time()
        if state["failed_at"] and time.time() - state["failed_at"] > 25:
            return "failed"
        return None

    p = wait_for(running, 150, 2)
    if not p or p == "failed":
        q = pod_json(NS, "pod")
        reason, message = waiting_message(q) if q else ("", "")
        fail("the Pod %s/pod, image %s, with its own secret, does not run: %s %s (events: %s)" % (NS, IMAGE, reason, short(message, 260), short(pod_events(NS, "pod"), 260)))
    cid = wait_for(lambda: container_id("pod", NS), 20, 1)
    log = ""

    def marker():
        global log
        log = run(CRICTL + ["logs", cid]).stdout if cid else ""
        return ("marker=%s" % nonce) in log

    if not wait_for(marker, 30, 2):
        fail("the container of the Pod does not print the marker of the new image (marker=%s); its log: %s" % (nonce, short(log)))

    # 5. what the registry saw: the manifest and the blobs of the new image, from CRI-O, as mirror.registry and as the registry's user; nothing for private.registry
    authorized, access, hosts = reg_log_since(off)
    if any(h.split(":")[0] == ORIG for h in hosts):
        fail("a request went to the registry as %s (hosts seen: %s): the rewrite was bypassed" % (ORIG, sorted(hosts)))
    mine = [a for a in authorized if a["uri"].startswith("/v2/team/app/") and a["method"] == "GET"]
    man = [a for a in mine if a["uri"] == "/v2/team/app/manifests/" + tag]
    blobs = [a for a in mine if "/blobs/" in a["uri"]]
    if not man or len(blobs) < 2:
        fail("the registry saw %d authorized manifest requests and %d blob requests for the new image from CRI-O: the image did not come through this registry (requests: %s)" % (len(man), len(blobs), short(json.dumps(mine), 200)))
    bad = [a for a in man + blobs if a["host"].split(":")[0] != MIRROR or a["user"] != c["user"]]
    if bad:
        fail("requests for the new image that are not mirror.registry as %s: %s" % (c["user"], short(json.dumps(bad), 220)))
    if not any(a["path"] == "/v2/team/app/manifests/" + tag and a["status"] == 200 and a["ua"].startswith("cri-o/1.25.2") for a in access):
        fail("no successful manifest request of cri-o/1.25.2 for the new image in the registry's access log")

    # 6. the registry still wants credentials after all this
    if reg("GET", "/v2/team/app/manifests/" + tag, auth=None)[0] != 401:
        fail("the registry gives the new image to an anonymous request")
finally:
    if NS:
        run(KUBECTL + ["delete", "namespace", NS, "--wait=false"])
    if IMAGE:
        run(CRICTL + ["rmi", IMAGE])
print("[oracle] PASS: the new image %s (marker %s) was pulled by a new Pod with its own secret through the rewrite: %d manifest and %d blob requests as mirror.registry by %s, none as private.registry; the Pod runs and prints the marker; the registry still answers 401 to anonymous requests; registries.conf, the registry and CRI-O 1.25.2 are untouched" % (IMAGE, nonce, len(man), len(blobs), c["user"]))
PYEOF
) || { echo "$OUT"; exit 1; }
echo "$OUT"
