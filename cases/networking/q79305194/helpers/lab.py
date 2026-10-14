#!/usr/bin/env python3
"""lab.py up|check|controls WORK : the record of what is true about the lab of q79305194 (run as root; verify.py uses it as a module).

The lab is one private containerd 2.0.0 (the unit bench79305194-containerd.service: the official 2.0.0 binaries below /var/lib/bench79305194/bin, configuration /etc/bench79305194/config.toml
with "version = 3", own root, state and CRI socket /run/bench79305194/containerd.sock) and one private registry (registry.py: registry.bench79305194.test:35791 on the machine's own non-loopback
address, plain HTTP, basic authentication; containerd treats loopback registries as plain HTTP by itself, so a loopback address would hide the problem). The configuration still has the
registry tables of a version 1/2 configuration under the plugin id io.containerd.grpc.v1.cri (a version 3 configuration reads them under io.containerd.cri.v1.images, with a config_path),
so the pull goes over HTTPS: "http: server gave HTTP response to HTTPS client". The credentials in it are under the key of Docker Hub, as they are in the Pod's secret.

  up        (after setup.sh started the service) preloads the pause image (ctr pull --plain-http, the CRI does not take part) and writes WORK/.bench/truth.json: the digests and the label of both
            images, the credentials, the hashes of the binaries, the unit, the blob store and the configuration, the identity of the registry process, the command line of the service.
  check     the lab is as it was (problems() and the configuration unchanged) and the service answers.
  controls  the control of precondition.sh: the registry answers 401 / 401 / 200 (no / wrong / right credentials); ctr (which takes --plain-http itself) pulls the image with the credentials
            and not with wrong ones; the CRI pull with the right credentials fails with "server gave HTTP response to HTTPS client"; the daemon is 2.0.0 with a version 3 configuration.

Used by verify.py: load(), problems(), crictl(), ctr(), pull(), wipe(), run_app(), service_pid(), tail_log(), ..."""
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time

CASE = "bench79305194"
HOST = "registry.bench79305194.test"
PORT = 35791
PAUSE_REF = "%s:%d/pause:3.6" % (HOST, PORT)
APP_REPO = "%s:%d/app" % (HOST, PORT)
UNIT = "bench79305194-containerd.service"
ETC = "/etc/bench79305194"
LIB = "/var/lib/bench79305194"
RUN = "/run/bench79305194"
CONF = ETC + "/config.toml"
SOCK = RUN + "/containerd.sock"
BIN = LIB + "/bin"
POD_CGROUP = "/bench79305194-pods"
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


def config_version():
    m = re.search(r"^\s*version\s*=\s*(\d+)\s*$", config_text(), re.M)
    return int(m.group(1)) if m else None


def legacy_tables():
    """the registry tables under the plugin id of the old CRI plugin"""
    return bool(re.search(r"^\s*\[+\s*plugins\.[\"']io\.containerd\.grpc\.v1\.cri[\"']\.registry", config_text(), re.M))


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


def pull(creds, ref):
    """a CRI pull as the kubelet does it (the credentials of the Pod's secret travel with the request): (return code, last line of the error)"""
    args = ["pull"]
    if creds:
        args += ["--creds", "%s:%s" % (creds["user"], creds["password"])]
    r = crictl(*args, ref, timeout=120)
    return r.returncode, (r.stderr or r.stdout).strip().split("\n")[-1]


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


def store_problem(t):
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
            if tags.get(repo, {}).get(tag) != d:
                return "the tag %s:%s of the registry's store was changed" % (repo, tag)
    return None


def problems(t):
    """what changed in the lab that the solution was not allowed to change (short texts; empty = as it was). The configuration of the service is NOT in this list: it is what has to be fixed."""
    p = []
    for name, want in t["bin_sha"].items():
        if sha_file("%s/%s" % (BIN, name)) != want:
            p.append("the binary %s of the lab (containerd %s) was replaced" % (name, VERSION))
    if sha_file("/etc/systemd/system/" + UNIT) != t["unit_sha"] or os.path.exists("/etc/systemd/system/%s.d" % UNIT):
        p.append("the unit %s was changed (the lab's containerd stays as the lab started it)" % UNIT)
    sp = store_problem(t)
    if sp:
        p.append(sp)
    if t["hosts_line"] not in open("/etc/hosts").read().splitlines():
        p.append("the line of /etc/hosts for %s was changed" % HOST)
    pid = t["registry"]["pid"]
    if proc_start(pid) != t["registry"]["start"] or "registry.py" not in (proc_cmdline(pid) or ""):
        p.append("the lab's registry was stopped or replaced (it stays plain HTTP with authentication)")
    return p


def up(work):
    bench, tp = paths(work)
    oci = json.load(open(os.path.join(bench, "oci.json")))
    cred = json.load(open(os.path.join(bench, "cred.json")))
    reg = find_proc("registry.py")
    if not reg:
        raise SystemExit("the registry is not running")
    if not wait_sock():
        raise SystemExit("containerd does not answer on %s" % SOCK)
    if server_version() != VERSION or config_version() != 3:
        raise SystemExit("the service is not containerd %s with a version 3 configuration (it says %s, version %s)" % (VERSION, server_version(), config_version()))
    r = ctr("-n", "k8s.io", "images", "pull", "--plain-http", "--user", "%s:%s" % (cred["user"], cred["password"]), PAUSE_REF, timeout=120)
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
    truth = {"creds": cred, "pause": oci["pause"], "app": oci["app"], "store": store, "blobs": blobs, "tags": json.load(open(os.path.join(store, "tags.json"))),
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
    cr = t["creds"]
    ip = t["hosts_line"].split()[0]
    base = ["curl", "-sS", "--noproxy", "*", "--max-time", "10", "-A", "bench79305194-lab", "-o", "/dev/null", "-w", "%{http_code}", "--resolve", "%s:%d:%s" % (HOST, PORT, ip)]
    url = "http://%s:%d/v2/" % (HOST, PORT)
    got = (run(base + [url]).stdout, run(base + ["--user", "%s:wrong" % cr["user"], url]).stdout, run(base + ["--user", "%s:%s" % (cr["user"], cr["password"]), url]).stdout)
    if got != ("401", "401", "200"):
        raise SystemExit("the registry should answer 401 / 401 / 200 (no / wrong / right credentials), it says %s" % "/".join(got))
    print("  -> OK control 1: the registry is plain HTTP and answers 401 without or with wrong credentials and 200 with the right ones (the authentication is valid and is not the problem)")
    ref = "%s:v1" % APP_REPO
    good, bad = "%s:%s" % (cr["user"], cr["password"]), "%s:wrong" % cr["user"]
    try:
        r1 = ctr("-n", "bench-ctl", "images", "pull", "--plain-http", "--user", bad, ref)
        r2 = ctr("-n", "bench-ctl", "images", "pull", "--plain-http", "--user", good, ref)
    finally:
        ctr("-n", "bench-ctl", "images", "rm", ref)
    if r1.returncode == 0 or r2.returncode != 0:
        raise SystemExit("ctr --plain-http should pull %s with the right credentials and not with wrong ones (%d / %d)" % (ref, r2.returncode, r1.returncode))
    print("  -> OK control 2: the daemon itself pulls the image over plain HTTP with the credentials (ctr --plain-http), and not with wrong ones")
    wipe()
    rc, err = pull(cr, ref)
    if rc == 0 or "HTTP response to HTTPS client" not in err:
        raise SystemExit("the CRI pull should fail with 'server gave HTTP response to HTTPS client', it says: %s" % ("pulled" if rc == 0 else short_error(err)))
    ver, ok = server_version(), images_plugin_ok()
    if ver != VERSION or config_version() != 3 or not ok or not legacy_tables() or config_path_set():
        raise SystemExit("the daemon should be %s with a version 3 configuration, a valid images plugin, old registry tables and no config_path (%s, v%s, plugin ok %s, old tables %s, config_path %s)"
                         % (VERSION, ver, config_version(), ok, legacy_tables(), config_path_set()))
    print("  -> OK control 3: containerd %s (version 3 configuration, CRI images plugin ok) fails the CRI pull with the right credentials: %s" % (ver, short_error(err, 110)))


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "check": check, "controls": controls}[cmd](work)
