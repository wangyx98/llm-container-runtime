#!/bin/bash
set -e

CASE_ID="bench77040211"
WORK_DIR="/tmp/$CASE_ID"

echo "[oracle] on each of the four nodes: the image is removed (and its blobs), the pinned digest is pulled through the CRI, a pod runs it with a fresh nonce; the registry's log must show the requests..."
OUT=$(sudo python3 - "$WORK_DIR" <<'PYEOF' 2>&1
import hashlib
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

CASE = "bench77040211"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
NODES = ["node1", "node2", "node3", "node4"]
ADDR, PORT = "10.77.40.11", 5000
REG = "%s:%d" % (ADDR, PORT)
REPO = "argus"
CA = LIB + "/pki/ca.crt"
CTL = LIB + "/bin/nodectl"
REGBIN = LIB + "/bin/registry"
REGCFG = LIB + "/registry/config.yml"
REGCRT = LIB + "/registry/registry.crt"
REGLOG = RUN + "/registry.log"
PAUSE_REF = CASE + ".local/pause:1"
UNKNOWN_CA = "signed by unknown authority"      # what a node says to a certificate of a CA it does not know (every Go version)


def run(argv, timeout=100):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", stdin=subprocess.DEVNULL)


def short(text, n=170):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 3] + "..."


def errtext(r, n=200):
    lines = [ln for ln in (r.stderr + "\n" + r.stdout).splitlines() if ln.strip() and "level=warning" not in ln]
    text = " ".join(lines)
    m = re.findall(r"desc = (.*)", text)
    return short(m[-1] if m else text, n)


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


def sock(n):
    return "%s/%s/run/containerd.sock" % (LIB, n)


def crictl(n, *args, timeout=100):
    return run(["crictl", "-r", "unix://" + sock(n), "-i", "unix://" + sock(n), "--timeout", "60s"] + list(args), timeout=timeout)


def ctr(n, ns, *args, timeout=100):
    return run(["ctr", "-a", sock(n), "-n", ns] + list(args), timeout=timeout)


def comm(pid):
    try:
        return open("/proc/%d/comm" % pid).read().strip()
    except OSError:
        return ""


def cmdline(pid):
    try:
        return open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode("latin-1").strip()
    except OSError:
        return ""


def start_time(pid):
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def load(work):
    return json.load(open(os.path.join(work, ".bench", "truth.json")))


def node_pid(n):
    try:
        return int(open("%s/%s/containerd.pid" % (LIB, n)).read().strip())
    except (OSError, ValueError):
        return 0


def node_problem(n):
    """the node must be the containerd that nodectl started, with the node's configuration file"""
    pid = node_pid(n)
    if not pid:
        return "%s: there is no containerd of nodectl (no pid file: the node was not started with nodectl)" % n
    want = "containerd --config %s/%s/etc/config.toml" % (LIB, n)
    if comm(pid) != "containerd" or cmdline(pid) != want:
        return "%s: the process %d is not the containerd of nodectl (command line: %s)" % (n, pid, short(cmdline(pid), 90))
    return None


def image_id(n, ref):
    r = crictl(n, "inspecti", "-o", "json", ref)
    try:
        return json.loads(r.stdout)["status"]["id"]
    except (ValueError, KeyError):
        return None


def wait_ready(n, t, timeout=60):
    """a restarted node answers late: wait until the CRI answers and the sandbox image is listed again"""
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(sock(n)) and crictl(n, "version").returncode == 0 and image_id(n, PAUSE_REF) == t["pause"][n]:
            return True
        time.sleep(0.5)
    return False


def tls_get(path, cafile):
    """GET https://REG/path with the given CA file (None: the host's own certificate store); returns the status"""
    ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=ctx))   # the sandbox exports the agent's proxy variables
    try:
        with opener.open("https://%s%s" % (REG, path), timeout=8) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def served_cert_sha():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with socket.create_connection((ADDR, PORT), timeout=8) as s, ctx.wrap_socket(s) as w:
        return hashlib.sha256(w.getpeercert(binary_form=True)).hexdigest()


def lab_problem(t):
    """what the solution must not change: nodectl, the registry (the same process, its configuration, HTTPS, the same certificate), the address, the host's certificate store"""
    if sha_file(CTL) != t["ctl_sha"]:
        return "nodectl was changed (the start of the nodes must stay as it is)"
    if sha_file(CA) != t["ca_sha"]:
        return "the lab CA file was changed"
    rp = t["reg_pid"]
    if comm(rp) != "registry" or start_time(rp) != t["reg_start"] or REGCFG not in cmdline(rp):
        return "the registry is not the process setup started (it was stopped or replaced)"
    if sha_file(REGCFG) != t["reg_cfg_sha"]:
        return "the configuration of the registry was changed"
    try:
        status = tls_get("/v2/", CA)
    except Exception as e:                                          # noqa: BLE001
        return "the registry does not answer over HTTPS at %s: %s" % (REG, short(str(e), 90))
    if status != 200:
        return "the registry answers %s at https://%s/v2/" % (status, REG)
    try:
        if served_cert_sha() != t["cert_sha"]:
            return "the registry serves another certificate than the one of setup"
    except Exception as e:                                          # noqa: BLE001
        return "the TLS handshake with the registry failed: %s" % short(str(e), 90)
    try:
        tls_get("/v2/", None)
        return "the lab CA is in the certificate store of this host (the registry certificate verifies against the system roots)"
    except ssl.SSLError:
        pass
    except Exception as e:                                          # noqa: BLE001
        if "CERTIFICATE_VERIFY_FAILED" not in str(e):
            return "unexpected answer of the registry for a client with the system roots: " + short(str(e), 90)
    for n in NODES:
        msg = node_problem(n)
        if msg:
            return msg
    return None


def reg_log_size():
    try:
        return os.path.getsize(REGLOG)
    except OSError:
        return 0


def reg_requests(offset):
    """the requests the registry logged after OFFSET: dicts with method, uri, status, ua"""
    with open(REGLOG, "rb") as f:
        f.seek(offset)
        lines = f.read().decode("latin-1").splitlines()
    out = []
    for ln in lines:
        if "response completed" not in ln:
            continue
        kv = {k: v.strip('"') for k, v in re.findall(r'([\w.]+)=("(?:[^"\\]|\\.)*"|\S+)', ln)}
        out.append({"method": kv.get("http.request.method", ""), "uri": kv.get("http.request.uri", ""),
                    "status": kv.get("http.response.status", ""), "ua": kv.get("http.request.useragent", "")})
    return out


def wipe_pods(n):
    for p in crictl(n, "pods", "-q").stdout.split():
        crictl(n, "stopp", p)
        crictl(n, "rmp", p)


def wipe_image(n, t):
    """the node must pull: the registry's images are removed from the CRI's store, and their blobs from the content store; returns an error text or None"""
    try:
        images = json.loads(crictl(n, "images", "-o", "json").stdout).get("images", [])
    except ValueError:
        images = []
    for im in images:
        names = im.get("repoTags", []) + im.get("repoDigests", [])
        if any(x.startswith(REG + "/") for x in names):
            crictl(n, "rmi", im["id"])
    for name in ctr(n, "k8s.io", "images", "ls", "-q").stdout.split():
        if name.startswith(REG + "/"):
            ctr(n, "k8s.io", "images", "rm", "--sync", name)
    for dg in (t["manifest"], t["config"], t["layer"]):
        if dg.split(":")[1] in ctr(n, "k8s.io", "content", "ls").stdout:
            ctr(n, "k8s.io", "content", "rm", dg)
    left = ctr(n, "k8s.io", "content", "ls").stdout
    for what in ("manifest", "config", "layer"):
        if t[what].split(":")[1] in left:
            return "the %s blob of the image could not be removed from the content store of %s" % (what, n)
    if image_id(n, t["ref"]):
        return "the image could not be removed from %s" % n
    return None


def run_app(n, t, nonce):
    """a new host-network pod and a container of the image whose program prints 'NONCE SALT'; returns (info, error)"""
    uid = secrets.token_hex(8)
    name = "argus-" + uid[:6]
    logdir = "%s/%s/log/pods/%s" % (LIB, n, uid)
    os.makedirs(logdir, exist_ok=True)
    pod = {"metadata": {"name": name, "namespace": "default", "uid": uid, "attempt": 0}, "log_directory": logdir,
           "labels": {"io.kubernetes.pod.name": name, "io.kubernetes.pod.namespace": "default", "io.kubernetes.pod.uid": uid},
           "linux": {"cgroup_parent": "/%s-%s" % (CASE, n), "security_context": {"namespace_options": {"network": 2}}}}
    ctr_ = {"metadata": {"name": "argus"}, "image": {"image": t["ref"]}, "args": [nonce], "log_path": "argus.log",
            "labels": {"io.kubernetes.container.name": "argus", "io.kubernetes.pod.name": name, "io.kubernetes.pod.namespace": "default", "io.kubernetes.pod.uid": uid},
            "linux": {"security_context": {"namespace_options": {"network": 2}}}}
    pf, cf = os.path.join(logdir, "pod.json"), os.path.join(logdir, "ctr.json")
    json.dump(pod, open(pf, "w"))
    json.dump(ctr_, open(cf, "w"))
    sid, r = "", None
    for _ in range(3):                                              # the first runp after a start can fail for a moment
        r = crictl(n, "runp", pf)
        if r.returncode == 0:
            sid = r.stdout.strip().splitlines()[-1]
            break
        time.sleep(2)
    if not sid:
        return None, "the pod sandbox did not start: " + errtext(r)
    r = crictl(n, "create", sid, cf, pf)
    if r.returncode != 0:
        return None, "the container was not created: " + errtext(r)
    cid = r.stdout.strip().splitlines()[-1]
    r = crictl(n, "start", cid)
    if r.returncode != 0:
        return None, "the container did not start: " + errtext(r)
    out, end = "", time.time() + 20
    while time.time() < end and nonce not in out:
        time.sleep(0.5)
        out = crictl(n, "logs", cid).stdout
    pid = 0
    try:
        pid = int(json.loads(crictl(n, "inspect", "-o", "json", cid).stdout)["info"]["pid"])
    except (ValueError, KeyError, TypeError):
        pass
    return {"pod": sid, "ctr": cid, "pid": pid, "log": out}, None


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def judge(n, t, i):
    """the node pulls the image cold and runs it; returns the first problem as text, or None"""
    if node_problem(n):
        return node_problem(n)
    wipe_pods(n)
    msg = wipe_image(n, t)
    if msg:
        return msg
    off = reg_log_size()
    r = crictl(n, "pull", t["ref"], timeout=150)
    if r.returncode != 0:
        if UNKNOWN_CA in r.stdout + r.stderr:
            return "%s still does not trust the registry's certificate: %s" % (n, errtext(r, 200))
        return "crictl pull %s failed on %s: %s" % (t["ref"], n, errtext(r, 200))
    if image_id(n, t["ref"]) != t["config"]:
        return "the image pulled by %s is not the pinned one (image id %s, expected %s)" % (n, (image_id(n, t["ref"]) or "none")[:19], t["config"][:19])
    reqs = [q for q in reg_requests(off) if q["ua"].startswith("containerd/") and q["status"] == "200" and q["method"] == "GET"]
    for what, uri in (("manifest", "/v2/%s/manifests/%s" % (REPO, t["manifest"])), ("config blob", "/v2/%s/blobs/%s" % (REPO, t["config"])),
                      ("layer blob", "/v2/%s/blobs/%s" % (REPO, t["layer"]))):
        if not any(q["uri"] == uri for q in reqs):
            return "the registry log has no request of containerd for the %s of the pinned image during the pull of %s (the image did not come from the registry)" % (what, n)
    nonce = secrets.token_hex(6)
    info, err = run_app(n, t, nonce)
    if err:
        return "%s: %s" % (n, err)
    if "%s %s" % (nonce, t["salt"]) not in info["log"]:
        return "the container on %s does not print the nonce and the salt of the pinned image: %s" % (n, short(info["log"], 100))
    salt_file = read("/proc/%d/root/salt" % info["pid"]) if info["pid"] else None
    if (salt_file or "").strip() != t["salt"]:
        return "the root of the running container on %s does not hold the salt of the pinned image" % n
    wipe_pods(n)
    return None


def main(work):
    t = load(work)
    for n in NODES:
        if not wait_ready(n, t, 60):
            log = (read("%s/%s/log/containerd.log" % (LIB, n)) or "").splitlines()
            bad = [ln for ln in log if re.search(r"level=(error|fatal)|failed to load|toml", ln)]
            fail("%s does not answer on its CRI socket (as the solution left it): %s" % (n, short((bad or log or ["no log"])[-1], 220)))
    msg = lab_problem(t)
    if msg:
        fail(msg)
    for i, n in enumerate(NODES):
        msg = judge(n, t, i)
        if msg:
            fail(msg)
        print("[oracle] %s ok: cold pull of the pinned digest from the registry (manifest and both blobs in its log), nonce workload runs" % n)


main(sys.argv[1])
PYEOF
) && RC=0 || RC=$?
echo "$OUT" | tail -8
[ "$RC" = 0 ] || { echo "[oracle] FAIL: see above"; exit 1; }

echo "[oracle] ALL CHECKS PASSED: node1 to node4 each pull the pinned image from the registry over HTTPS and run it."
