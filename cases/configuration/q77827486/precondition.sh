#!/bin/bash
set -e

CASE_ID="bench77827486"
WORK_DIR="/tmp/$CASE_ID"

echo "[precondition] the lab as recorded; the credentials are right and the registry wants them; the rewrite makes CRI-O drop them and the Pod my-ns/pod cannot pull; controls: the same credentials work on mirror.registry directly..."
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
    print("[precondition] FAIL: " + msg)
    sys.exit(1)


t, c = truth(), creds()
CTL = "team/ctl"
TEXT = "unauthorized: authentication required"

# the lab as recorded
if run(["getent", "hosts", ORIG]).stdout.split()[:1] != ["127.78.27.1"] or run(["getent", "hosts", MIRROR]).stdout.split()[:1] != ["127.78.27.1"]:
    fail("private.registry and mirror.registry do not both resolve to 127.78.27.1")
rp = int(read(RUN + "/registry.pid") or 0)
if not rp or not os.path.exists("/proc/%d" % rp) or open("/proc/%d/stat" % rp).read().rsplit(")", 1)[1].split()[19] != t["registry_start"]:
    fail("the registry is not the process of setup.sh")
if sha_file(LIB + "/registry/config.yml") != t["registry_config_sha"] or sha_file(LIB + "/registry/htpasswd") != t["htpasswd_sha"] or sha_file(RUN + "/registries.conf") != t["registries_conf_sha"]:
    fail("the registry's configuration, its password file or registries.conf is not the one of setup.sh")
if sha_file(LIB + "/opt/crio/crio") != t["crio_sha"]:
    fail("the crio program is not the pinned one")
v = run(CRICTL + ["version"])
if "RuntimeVersion:  1.25.2" not in v.stdout or "RuntimeName:  cri-o" not in v.stdout:
    fail("the runtime is not CRI-O 1.25.2: " + short(v.stdout + v.stderr))
if "True" not in run(KUBECTL + ["get", "node", NODE, "-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}"]).stdout:
    fail("the node is not Ready")
if "v1.26.4+k3s1" not in run(KUBECTL + ["get", "node", NODE, "-o", "jsonpath={.status.nodeInfo.kubeletVersion}"]).stdout:
    fail("the kubelet is not v1.26.4+k3s1")

# control 1: the registry wants credentials, and these are the right ones; the secret holds them
if reg("GET", "/v2/", auth=None)[0] != 401 or reg("GET", "/v2/", auth="bad")[0] != 401 or reg("GET", "/v2/")[0] != 200:
    fail("control 1: the registry does not answer 401 without credentials or with a wrong password, and 200 with the right ones")
sec = run(KUBECTL + ["-n", "my-ns", "get", "secret", "registry-secret", "-o", "jsonpath={.data.\\.dockerconfigjson}"]).stdout
try:
    auths = json.loads(base64.b64decode(sec))["auths"]
except ValueError:
    fail("the secret my-ns/registry-secret has no .dockerconfigjson")
ent = auths.get(ORIG) or {}
if list(auths) != [ORIG] or base64.b64decode(ent.get("auth", "")).decode() != "%s:%s" % (c["user"], c["password"]):
    fail("the secret does not hold the registry's credentials for " + ORIG)

# control 2: with these credentials CRI-O pulls from mirror.registry itself (no rewrite for that name)
tag = "c" + os.urandom(4).hex()
push_image(CTL, tag, ST + "/marker", tag, "/marker")
creds_arg = ["--creds", "%s:%s" % (c["user"], c["password"])]
try:
    r = run(CRICTL + ["pull"] + creds_arg + ["%s/%s:%s" % (MIRROR, CTL, tag)])
    if r.returncode != 0:
        fail("control 2: CRI-O cannot pull %s/%s:%s with the credentials: %s" % (MIRROR, CTL, tag, short(r.stdout + r.stderr)))
    run(CRICTL + ["rmi", "%s/%s:%s" % (MIRROR, CTL, tag)])

    # control 3 (the question): the same credentials given for the name the rewrite applies to are not used, whether they come from crictl or the kubelet
    off = reg_log_size()
    r = run(CRICTL + ["pull"] + creds_arg + ["%s/%s:%s" % (ORIG, CTL, tag)])
    msg = r.stdout + r.stderr
    if r.returncode == 0 or "reading manifest %s in %s/%s: %s" % (tag, MIRROR, CTL, TEXT) not in msg:
        fail("control 3: the pull of %s/%s:%s with the right credentials did not fail the way the question says: %s" % (ORIG, CTL, tag, short(msg)))
    authorized, access, hosts = reg_log_since(off)
    if any("/%s/" % CTL in a["uri"] for a in authorized) or not any(a["status"] == 401 and CTL in a["path"] and a["ua"].startswith("cri-o/1.25.2") for a in access):
        fail("control 3: the registry did not see an unauthenticated request of CRI-O for %s (the credentials would have been sent)" % CTL)
finally:
    run(CRICTL + ["rmi", "%s/%s:%s" % (MIRROR, CTL, tag)])
    run(CRICTL + ["rmi", "%s/%s:%s" % (ORIG, CTL, tag)])

# the Pod of the question: its secret is right, its pull fails the same way
def waiting():
    p = pod_json("my-ns", "pod")
    reason, message = waiting_message(p) if p else ("", "")
    return message if reason in ("ErrImagePull", "ImagePullBackOff") and TEXT in message else None


m = wait_for(waiting, 150, 3)
if not m:
    p = pod_json("my-ns", "pod")
    fail("the Pod my-ns/pod does not fail with '%s' (status: %s; events: %s)" % (TEXT, short(json.dumps((p or {}).get("status", {}).get("containerStatuses")), 160), short(pod_events("my-ns", "pod"), 240)))
print("[precondition] OK: CRI-O 1.25.2 on Kubernetes v1.26.4+k3s1; the registry wants the credentials and the secret holds the right ones; CRI-O pulls %s/%s with them and drops them for %s/%s (%s); the Pod my-ns/pod: %s" % (MIRROR, CTL, ORIG, CTL, TEXT, short(m, 150)))
PYEOF
) || { echo "$OUT"; exit 1; }
echo "$OUT"
