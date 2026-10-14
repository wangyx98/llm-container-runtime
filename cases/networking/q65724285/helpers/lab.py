#!/usr/bin/env python3
"""lab.py up|check|controls WORK : the record of what is true about the lab of q65724285 (run as root; verify.py uses it as a module).

The lab is one private containerd 2.0.0 (the unit bench65724285-containerd.service: the official 2.0.0 binaries below /var/lib/bench65724285/bin, configuration /etc/bench65724285/config.toml
(version 2, the format of the question), own root, state and CRI socket /run/bench65724285/containerd.sock) and one private registry (registry.py: registry.bench65724285.test:5000 on the
machine's own non-loopback address, plain HTTP, no authentication; containerd treats loopback registries as plain HTTP by itself, so a loopback address would hide the problem). The
workload is registry.bench65724285.test:5000/my-alpine:latest, and it has TWO entrances that read different things:

  ctr   (the client of the question: `ctr images pull REF`) does not read config.toml at all: its pulls go to https://HOST:5000 unless the command names a hosts directory
        (`--hosts-dir DIR`, one directory HOST:5000 with a hosts.toml in it) or says --plain-http. The check uses the exact command `ctr -a SOCK images pull --hosts-dir
        /etc/bench65724285/certs.d REF`, in ctr's default namespace; the directory does not exist at the start.
  CRI   (crictl, the kubelet; here a pull, a sandbox and a container) reads config.toml: its registry tables key HOST:5000 have an insecure_skip_verify entry (which does not turn https into
        http) and a mirror whose endpoint is https://HOST:5000, a typo of the question's http://, so the pull still speaks TLS to the plain HTTP registry.

  up        (after setup.sh started the service) preloads the pause image (ctr pull --plain-http, the CRI does not take part) and writes WORK/.bench/truth.json: the digests and the label of the
            images, the hashes of the binaries, the unit, the blob store, the identity of the registry process, the command line of the service.
  check     the lab is as it was (problems() and the configuration unchanged) and the service answers.
  controls  the control of precondition.sh: the registry answers on port 5000; ctr --plain-http pulls the image (the registry is fine); the exact ctr command of the check fails with "server gave
            HTTP response to HTTPS client" (no hosts directory); the CRI pull fails with the same text and the mirror endpoint is https.

Used by verify.py: load(), problems(), crictl(), ctr(), pull(), ctr_pull(), ctr_run(), wipe(), run_app(), service_pid(), tail_log(), ..."""
import hashlib
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import time

CASE = "bench65724285"
HOST = "registry.bench65724285.test"
PORT = 5000
REGISTRY = "%s:%d" % (HOST, PORT)
PAUSE_REF = "%s/pause:3.6" % REGISTRY
APP_REPO = "%s/my-alpine" % REGISTRY
APP_REF = APP_REPO + ":latest"
HOSTS_DIR = "/etc/bench65724285/certs.d"           # the hosts directory of the exact ctr command (--hosts-dir)
UNIT = "bench65724285-containerd.service"
ETC = "/etc/bench65724285"
LIB = "/var/lib/bench65724285"
RUN = "/run/bench65724285"
CONF = ETC + "/config.toml"
SOCK = RUN + "/containerd.sock"
BIN = LIB + "/bin"
POD_CGROUP = "/bench65724285-pods"
VERSION = "v2.0.0"


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json")


def load(work):
    return json.load(open(paths(work)[1]))


def sha_file(p):
    try:
        return hashlib.sha256(open(p, "rb").read()).hexdigest()
    except OSError:
        return None


def run(argv, timeout=100):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp")


def crictl(*args, timeout=100):
    return run(["crictl", "-r", "unix://" + SOCK, "-i", "unix://" + SOCK, "--timeout", "60s"] + list(args), timeout=timeout)


def ctr(*args, timeout=100):
    return run([BIN + "/ctr", "--address", SOCK] + list(args), timeout=timeout)


def systemctl(*args, timeout=120):
    return run(["systemctl"] + list(args), timeout=timeout)


def service_pid():
    try:
        return int(systemctl("show", "-p", "MainPID", "--value", UNIT).stdout.strip())
    except ValueError:
        return 0


def proc_cmdline(pid):
    try:
        return open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode("latin-1").strip()
    except OSError:
        return None


def proc_start(pid):
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def find_proc(script):
    for d in os.listdir("/proc"):
        if d.isdigit():
            c = proc_cmdline(int(d)) or ""
            if re.search(r"python3? .*/%s " % re.escape(script), c) and CASE in c:
                return int(d)
    return 0


def wait_sock(timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(SOCK) and crictl("version").returncode == 0:
            return True
        time.sleep(0.4)
    return False


def server_version():
    """the version line of the server block of `ctr version` ("v2.0.0"), or None"""
    out = ctr("version").stdout
    m = re.search(r"Server:\s*\n\s*Version:\s*(\S+)", out)
    return m.group(1) if m else None


def images_plugin_ok():
    for ln in ctr("plugins", "ls").stdout.splitlines():
        f = ln.split()
        if len(f) >= 2 and f[0] == "io.containerd.cri.v1" and f[1] == "images":
            return f[-1] == "ok"
    return False


def config_text():
    try:
        return open(CONF).read()
    except OSError:
        return ""


def mirror_endpoint():
    """the endpoint of the mirror of HOST:PORT in the legacy tables, or None"""
    m = re.search(r"registry\.mirrors\.[\"']%s[\"']\]\s*\n\s*endpoint\s*=\s*\[\s*[\"']([^\"']+)[\"']" % re.escape(REGISTRY), config_text())
    return m.group(1) if m else None


def hosts_toml():
    p = "%s/%s/hosts.toml" % (HOSTS_DIR, REGISTRY)
    return open(p).read() if os.path.isfile(p) else None


def legacy_tables():
    """mirrors or configs tables of the old registry format"""
    return bool(re.search(r"^\s*\[+\s*plugins\.[\"']io\.containerd\.grpc\.v1\.cri[\"']\.registry\.(mirrors|configs)", config_text(), re.M))


def config_path_set():
    return bool(re.search(r"^\s*config_path\s*=\s*[\"'][^\"']+[\"']", config_text(), re.M))


def images():
    r = crictl("images", "-o", "json")
    try:
        return json.loads(r.stdout).get("images", [])
    except ValueError:
        return []


def wipe():
    """remove every sandbox and container of the service and every image except the pause image; returns True if the pause image is still there"""
    for p in crictl("pods", "-q").stdout.split():
        crictl("stopp", p)
        crictl("rmp", "-f", p)
    pause = False
    for i in images():
        if PAUSE_REF in (i.get("repoTags") or []):
            pause = True
        else:
            crictl("rmi", i["id"])
    return pause


def pull(ref):
    """a CRI pull (crictl pull, no credentials: the registry has none): (return code, last line of the error)"""
    r = crictl("pull", ref, timeout=120)
    return r.returncode, (r.stderr or r.stdout).strip().split("\n")[-1]


def ctr_pull(ref):
    """the exact ctr command of the check, default namespace: (return code, last line of the error)"""
    r = ctr("images", "pull", "--hosts-dir", HOSTS_DIR, ref, timeout=120)
    return r.returncode, (r.stderr or r.stdout).strip().split("\n")[-1]


def ctr_images(ref):
    """the lines of `ctr images ls` (default namespace) for REF: [(name, digest)]"""
    out = []
    for ln in ctr("images", "ls").stdout.splitlines()[1:]:
        f = ln.split()
        if len(f) >= 3 and f[0] == ref:
            out.append((f[0], f[2]))
    return out


def ctr_run(ref, nonce):
    """ctr run --rm (default namespace, the program prints its nonce and label and leaves): (ok, {"nonce", "label"} | reason)"""
    r = ctr("run", "--rm", ref, "c" + secrets.token_hex(4), "/app", nonce, "once", timeout=120)
    m = re.search(r"nonce=(\S+) label=(\S+)", r.stdout)
    if r.returncode != 0 or not m:
        return False, "ctr run failed: " + short_error((r.stderr or r.stdout).strip().split("\n")[-1])
    return True, {"nonce": m.group(1), "label": m.group(2)}


def short_error(text, n=170):
    """the reason in the error of crictl, without the names that every error repeats"""
    t = text.replace('\\"', '"')
    t = re.sub(r'^.*?level=fatal msg="', "", t)
    t = t.split("desc = ", 1)[-1]
    t = re.sub(r"^(pulling image: )?failed to pull and unpack image \S+: failed to resolve reference \S+: ", "", t)
    t = re.sub(r"^failed to do request: ", "", t)
    t = re.sub(r'(Head|Get) "https?://[^"]+": ', "", t)
    return t.rstrip('" ')[:n]


def run_app(work, ref, nonce):
    """a sandbox (host network) with one container of REF that prints its nonce and label: (ok, dict of what the log says | reason, pod id)"""
    out = os.path.join(work, "out")
    os.makedirs(out, exist_ok=True)
    os.chmod(out, 0o755)
    name = "p" + secrets.token_hex(4)
    logs = os.path.join(out, "logs-" + name)
    os.makedirs(logs, exist_ok=True)
    pod = {"metadata": {"name": name, "namespace": "default", "uid": secrets.token_hex(8), "attempt": 1}, "log_directory": logs,
           "linux": {"cgroup_parent": POD_CGROUP, "security_context": {"namespace_options": {"network": 2}}}}
    ctn = {"metadata": {"name": "c" + name}, "image": {"image": ref}, "command": ["/app"], "args": [nonce], "log_path": "c.log", "linux": {}}
    pj, cj = os.path.join(out, name + ".json"), os.path.join(out, name + "-c.json")
    json.dump(pod, open(pj, "w"))
    json.dump(ctn, open(cj, "w"))
    r = crictl("runp", pj, timeout=120)
    if r.returncode != 0:
        return False, "runp failed: " + short_error(r.stderr), None
    pid = r.stdout.strip().split("\n")[-1]
    r = crictl("create", pid, cj, pj, timeout=120)
    if r.returncode != 0:
        return False, "create failed: " + short_error(r.stderr), pid
    cid = r.stdout.strip().split("\n")[-1]
    r = crictl("start", cid)
    if r.returncode != 0:
        return False, "start failed: " + short_error(r.stderr), pid
    end = time.time() + 20
    while time.time() < end:
        try:
            txt = open(os.path.join(logs, "c.log")).read()
        except OSError:
            txt = ""
        m = re.search(r" F nonce=(\S+) label=(\S+)", txt)
        if m:
            return True, {"nonce": m.group(1), "label": m.group(2)}, pid
        time.sleep(0.3)
    return False, "the container printed nothing", pid


def pod_down(pid):
    if pid:
        crictl("stopp", pid)
        crictl("rmp", "-f", pid)


def tail_log(path, offset):
    out = []
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            for ln in f.read().decode("utf-8", "replace").splitlines():
                try:
                    out.append(json.loads(ln))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def size(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def store_problem(t, replaced=()):
    """the images the lab made are still in the registry's store as they were (the oracle adds one of its own, so the store as a whole may differ)"""
    for d in t["blobs"]:
        if sha_file(os.path.join(t["store"], "blobs", "sha256", d[7:])) != d[7:]:
            return "an image of the registry's store was changed"
    try:
        tags = json.load(open(os.path.join(t["store"], "tags.json")))
    except (OSError, ValueError):
        return "the tag list of the registry's store is gone"
    for repo, m in t["tags"].items():
        for tag, d in m.items():
            if tag not in replaced and tags.get(repo, {}).get(tag) != d:
                return "the tag %s:%s of the registry's store was changed" % (repo, tag)
    return None


def problems(t, replaced=()):
    """what changed in the lab that the solution was not allowed to change (short texts; empty = as it was). The configuration of the service is NOT in this list: it is what has to be fixed."""
    p = []
    for name, want in t["bin_sha"].items():
        if sha_file("%s/%s" % (BIN, name)) != want:
            p.append("the binary %s of the lab (containerd %s) was replaced" % (name, VERSION))
    if sha_file("/etc/systemd/system/" + UNIT) != t["unit_sha"] or os.path.exists("/etc/systemd/system/%s.d" % UNIT):
        p.append("the unit %s was changed (the lab's containerd stays as the lab started it)" % UNIT)
    sp = store_problem(t, replaced)
    if sp:
        p.append(sp)
    if t["hosts_line"] not in open("/etc/hosts").read().splitlines():
        p.append("the line of /etc/hosts for %s was changed" % HOST)
    pid = t["registry"]["pid"]
    if proc_start(pid) != t["registry"]["start"] or "registry.py" not in (proc_cmdline(pid) or ""):
        p.append("the lab's registry was stopped or replaced (it stays plain HTTP on port 5000)")
    return p


def up(work):
    bench, tp = paths(work)
    oci = json.load(open(os.path.join(bench, "oci.json")))
    reg = find_proc("registry.py")
    if not reg:
        raise SystemExit("the registry is not running")
    if not wait_sock():
        raise SystemExit("containerd does not answer on %s" % SOCK)
    if server_version() != VERSION or not images_plugin_ok():
        raise SystemExit("the service is not containerd %s with a valid CRI images plugin (it says %s)" % (VERSION, server_version()))
    r = ctr("-n", "k8s.io", "images", "pull", "--plain-http", PAUSE_REF, timeout=120)
    if r.returncode != 0:
        raise SystemExit("the pause image could not be preloaded: " + short_error(r.stderr))
    if not [i for i in images() if PAUSE_REF in (i.get("repoTags") or [])]:
        systemctl("restart", UNIT)                       # the CRI plugin reads its image store when it starts
        if not wait_sock() or not [i for i in images() if PAUSE_REF in (i.get("repoTags") or [])]:
            raise SystemExit("the CRI does not list the preloaded pause image")
    if [i for i in images() if i["id"] != oci["pause"]["config"] and i["id"] != oci["pause"]["config"][7:]] or crictl("pods", "-q").stdout.strip():
        raise SystemExit("the store of the service is not as expected")
    pid = service_pid()
    store = os.path.join(bench, "registry")
    blobs = ["sha256:" + f for f in sorted(os.listdir(os.path.join(store, "blobs", "sha256")))]
    truth = {"pause": oci["pause"], "app": oci["app"], "store": store, "blobs": blobs, "tags": json.load(open(os.path.join(store, "tags.json"))),
             "bin_sha": {n: sha_file("%s/%s" % (BIN, n)) for n in ("containerd", "ctr", "containerd-shim-runc-v2")}, "unit_sha": sha_file("/etc/systemd/system/" + UNIT),
             "conf_sha": sha_file(CONF), "hosts_line": open(os.path.join(bench, "hosts_line")).read().strip(), "registry": {"pid": reg, "start": proc_start(reg)},
             "service_cmdline": proc_cmdline(pid), "registry_log": os.path.join(bench, "registry.log"), "app_bin": os.path.join(bench, "app")}
    with open(tp + ".tmp", "w") as f:
        json.dump(truth, f)
    os.replace(tp + ".tmp", tp)


def check(work):
    t = load(work)
    pr = problems(t)
    if pr:
        raise SystemExit(pr[0])
    if sha_file(CONF) != t["conf_sha"]:
        raise SystemExit("the configuration %s is not as the lab made it" % CONF)
    if systemctl("is-active", UNIT).stdout.strip() != "active" or crictl("version").returncode != 0:
        raise SystemExit("%s is not active" % UNIT)


def controls(work):
    t = load(work)
    ip = t["hosts_line"].split()[0]
    base = ["curl", "-sS", "--noproxy", "*", "--max-time", "10", "-A", "bench65724285-lab", "-o", "/dev/null", "-w", "%{http_code}", "--resolve", "%s:%d:%s" % (HOST, PORT, ip)]
    got = (run(base + ["http://%s/v2/" % REGISTRY]).stdout, run(base + ["http://%s/v2/my-alpine/manifests/latest" % REGISTRY]).stdout)
    if got != ("200", "200"):
        raise SystemExit("the registry should answer 200 on /v2/ and for my-alpine:latest on port %d over plain HTTP, it says %s" % (PORT, "/".join(got)))
    print("  -> OK control 1: the registry is plain HTTP on port %d (no authentication) and serves my-alpine:latest" % PORT)
    try:
        r = ctr("-n", "bench-ctl", "images", "pull", "--plain-http", APP_REF)
    finally:
        ctr("-n", "bench-ctl", "images", "rm", APP_REF)
    if r.returncode != 0:
        raise SystemExit("ctr --plain-http should pull %s: %s" % (APP_REF, short_error(r.stderr)))
    print("  -> OK control 2: the daemon itself pulls %s over plain HTTP (ctr --plain-http): the registry is fine; the question is what ctr and the CRI each read" % APP_REF.split("/", 1)[1])
    rc, err = ctr_pull(APP_REF)
    if rc == 0 or "HTTP response to HTTPS client" not in err or hosts_toml() is not None:
        raise SystemExit("the exact ctr command of the check should fail with 'server gave HTTP response to HTTPS client' (no hosts directory), it says: %s" % ("pulled" if rc == 0 else short_error(err)))
    ep = mirror_endpoint()
    wipe()
    rc2, err2 = pull(APP_REF)
    ok = images_plugin_ok()
    if rc2 == 0 or "HTTP response to HTTPS client" not in err2:
        raise SystemExit("the CRI pull should fail with 'server gave HTTP response to HTTPS client', it says: %s" % ("pulled" if rc2 == 0 else short_error(err2)))
    if server_version() != VERSION or not ok or ep != "https://" + REGISTRY or config_path_set():
        raise SystemExit("the daemon should be %s with a valid CRI images plugin, the mirror endpoint https://%s and no config_path (%s, plugin ok %s, endpoint %s, config_path %s)"
                         % (VERSION, REGISTRY, server_version(), ok, ep, config_path_set()))
    print("  -> OK control 3: both entrances fail with the HTTPS error: ctr with the hosts-dir command of the check (the directory does not exist; ctr does not read config.toml), the CRI "
          "(containerd %s, images plugin ok) although the configuration has skip_verify and a mirror: its endpoint is %s" % (VERSION, ep))


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "check": check, "controls": controls}[cmd](work)
