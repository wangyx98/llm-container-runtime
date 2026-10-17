#!/usr/bin/env python3
"""lab.py up|check|controls WORK : the lab of q66642654 (run as root by setup.sh, precondition.sh and, as a module, by verify.py).

The node is a model of a MicroK8s node: a private containerd that `mk8sctl` starts through `mk8s-run-containerd`, which makes args/containerd.toml again from
args/containerd-template.toml at EVERY start (as the MicroK8s snap does). Next to it a plain-HTTP registry on the address 10.66.64.45 (a /32 alias of `lo`: containerd treats loopback
registries as plain HTTP by itself, so the registry must not be on 127.x), port 32000, holding myapp:latest.

  up        records what is true (launcher and control script hashes, the registry process, the sandbox image) in WORK/.bench/truth.json and pushes the first build of myapp
  check     the lab is as the record says: prints the first problem, exit 1
  controls  1) the node cannot pull myapp over the CRI (the HTTPS text of the question), 2) the asker's own try (a registry entry written into the generated containerd.toml, then a restart)
            is undone by the restart and the pull still fails, 3) a throw-away containerd with the same template and a registry entry pulls the image (the lab is solvable)

verify.py uses push(), pull(), run_app() and problems() of this module."""
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
import urllib.request

CASE = "bench66642654"
LIB = "/var/lib/" + CASE
SNAP_DATA = LIB + "/current"
SNAP_COMMON = LIB + "/common"
ARGS = SNAP_DATA + "/args"
TEMPLATE = ARGS + "/containerd-template.toml"
GENERATED = ARGS + "/containerd.toml"
SOCK = SNAP_COMMON + "/run/containerd.sock"
PIDF = SNAP_COMMON + "/run/containerd.pid"
LOGF = SNAP_COMMON + "/var/log/containerd.log"
BIN = LIB + "/bin"
CTL = BIN + "/mk8sctl"
LAUNCHER = BIN + "/mk8s-run-containerd"
RUN = "/run/" + CASE
REGDIR = RUN + "/registry"
REGLOG = RUN + "/registry.log"
ADDR = "10.66.64.45"
PORT = 32000
REG = "%s:%d" % (ADDR, PORT)
REPO = "myapp"
REF = "%s/%s:latest" % (REG, REPO)
PAUSE_REF = CASE + ".local/pause:1"
POD_CGROUP = "/%s-pods" % CASE
# what a pull over https says to a plain-HTTP registry depends on the Go version containerd was built with
HTTPS_TEXTS = ("server gave HTTP response to HTTPS client", "first record does not look like a TLS handshake")


def https_error(text):
    return any(t in text for t in HTTPS_TEXTS)


MIRROR = "[plugins.'io.containerd.cri.v1.images'.registry.mirrors.'%s']\n  endpoint = ['http://%s']\n" % (REG, REG)


def bench_dir(work):
    return os.path.join(work, ".bench")


def load(work):
    return json.load(open(os.path.join(bench_dir(work), "truth.json")))


def run(argv, timeout=100, env=None):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", stdin=subprocess.DEVNULL, env=env)


def crictl(*args, sock=SOCK, timeout=100):
    return run(["crictl", "-r", "unix://" + sock, "-i", "unix://" + sock, "--timeout", "60s"] + list(args), timeout=timeout)


def short(text, n=170):
    text = re.sub(r"\s+", " ", text or "").strip()
    return text if len(text) <= n else text[:n - 3] + "..."


def errtext(r, n=200):
    """what a failed command said, without crictl's warning about /etc/crictl.yaml"""
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


def render(text, data=SNAP_DATA, common=SNAP_COMMON):
    """what mk8s-run-containerd makes of the template"""
    return text.replace("${SNAP_DATA}", data).replace("${SNAP_COMMON}", common)


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


def find_pid(name, needle):
    for d in os.listdir("/proc"):
        if d.isdigit() and comm(int(d)) == name and needle in cmdline(int(d)):
            return int(d)
    return 0


def node_pid():
    try:
        return int(open(PIDF).read().strip())
    except (OSError, ValueError):
        return 0


def wait_sock(sock=SOCK, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(sock) and crictl("version", sock=sock).returncode == 0:
            return True
        time.sleep(0.4)
    return False


def image_id(ref, sock=SOCK):
    r = crictl("inspecti", "-o", "json", ref, sock=sock)
    try:
        return json.loads(r.stdout)["status"]["id"]
    except (ValueError, KeyError):
        return None


def wait_ready(timeout=60):
    """a restarted node answers late: wait until the CRI answers and the sandbox image is listed again"""
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(SOCK) and crictl("version").returncode == 0 and image_id(PAUSE_REF):
            return True
        time.sleep(0.5)
    return False


def http_get(url, timeout=5):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))      # the sandbox exports the agent's proxy variables
    with opener.open(url, timeout=timeout) as r:
        return r.status, r.read()


def alias_present():
    return any(ln.strip() == "|-- " + ADDR for ln in open("/proc/net/fib_trie"))


def problems(t):
    """what the solution must not have changed: the launcher and the control script, the registry (the same process, plain HTTP, same address), the address, and that the
    containerd that answers is the one mk8sctl started with the node's configuration. Returns the first problem as text, or None."""
    for path, key, what in ((LAUNCHER, "launcher_sha", "mk8s-run-containerd"), (CTL, "ctl_sha", "mk8sctl")):
        if sha_file(path) != t[key]:
            return "%s was changed (the node's start must stay as it is)" % what
    if not alias_present():
        return "the registry address %s is gone from this host" % ADDR
    rp = t["registry_pid"]
    if comm(rp) != "python3" or start_time(rp) != t["registry_start"] or REGDIR not in cmdline(rp):
        return "the registry fixture is not the process setup started (it was stopped or replaced)"
    try:
        status, _ = http_get("http://%s/v2/" % REG)
    except Exception as e:                                          # noqa: BLE001
        return "the registry does not answer over plain HTTP at %s: %s" % (REG, short(str(e), 80))
    if status != 200:
        return "the registry answers %s at http://%s/v2/" % (status, REG)
    return None


def identity_problem():
    """the node's containerd must be the process that mk8s-run-containerd exec'd: pid file of the launcher, command line with the generated file"""
    pid = node_pid()
    if not pid:
        return "there is no containerd of mk8sctl (no pid file: the node was not started with mk8sctl)"
    if comm(pid) != "containerd" or cmdline(pid) != "containerd --config " + GENERATED:
        return "the process %d is not the containerd of mk8sctl (command line: %s)" % (pid, short(cmdline(pid), 90))
    return None


def reg_log_size():
    try:
        return os.path.getsize(REGLOG)
    except OSError:
        return 0


def reg_log_since(offset):
    with open(REGLOG, "rb") as f:
        f.seek(offset)
        return f.read().decode("latin-1").splitlines()


def push(work, salt):
    """a NEW build of myapp:latest (a new salt is a new image with new digests) pushed with the plain distribution API; returns the digests"""
    bench = bench_dir(work)
    r = run(["python3", os.path.join(bench, "mkimg.py"), "push", "http://" + REG, REPO, "latest", os.path.join(bench, "app-bin"), "app", salt], timeout=60)
    if r.returncode != 0:
        raise RuntimeError("the lab could not push a new build: " + short(r.stderr))
    return json.loads(r.stdout.strip().splitlines()[-1])


def pull(timeout=100):
    return crictl("pull", REF, timeout=timeout)


def wipe_pods():
    for p in crictl("pods", "-q").stdout.split():
        crictl("stopp", p)
        crictl("rmp", p)


def wipe_app_images():
    """the node must pull: every image of the registry is removed from the CRI's store first (the sandbox image stays)"""
    try:
        images = json.loads(crictl("images", "-o", "json").stdout).get("images", [])
    except ValueError:
        return
    for im in images:
        if any(tag.startswith(REG + "/") for tag in im.get("repoTags", [])):
            crictl("rmi", im["id"])


def run_app(work, nonce):
    """a new host-network pod and a container of REF whose program prints 'NONCE SALT'; returns (info, error)"""
    uid = secrets.token_hex(8)
    name = "myapp-" + uid[:6]
    logdir = "%s/var/log/pods/%s" % (SNAP_COMMON, uid)
    os.makedirs(logdir, exist_ok=True)
    pod = {"metadata": {"name": name, "namespace": "default", "uid": uid, "attempt": 0}, "log_directory": logdir,
           "labels": {"io.kubernetes.pod.name": name, "io.kubernetes.pod.namespace": "default", "io.kubernetes.pod.uid": uid},
           "linux": {"cgroup_parent": POD_CGROUP, "security_context": {"namespace_options": {"network": 2}}}}
    ctr = {"metadata": {"name": "myapp"}, "image": {"image": REF}, "args": [nonce], "log_path": "myapp.log",
           "labels": {"io.kubernetes.container.name": "myapp", "io.kubernetes.pod.name": name, "io.kubernetes.pod.namespace": "default", "io.kubernetes.pod.uid": uid},
           "linux": {"security_context": {"namespace_options": {"network": 2}}}}
    pf, cf = os.path.join(bench_dir(work), "pod-%s.json" % uid[:6]), os.path.join(bench_dir(work), "ctr-%s.json" % uid[:6])
    json.dump(pod, open(pf, "w"))
    json.dump(ctr, open(cf, "w"))
    sid = ""
    for _ in range(3):                                              # the first runp after a start can fail for a moment
        r = crictl("runp", pf)
        if r.returncode == 0:
            sid = r.stdout.strip().splitlines()[-1]
            break
        time.sleep(2)
    if not sid:
        return None, "the pod sandbox did not start: " + errtext(r)
    r = crictl("create", sid, cf, pf)
    if r.returncode != 0:
        return None, "the container was not created: " + errtext(r)
    cid = r.stdout.strip().splitlines()[-1]
    r = crictl("start", cid)
    if r.returncode != 0:
        return None, "the container did not start: " + errtext(r)
    out, end = "", time.time() + 20
    while time.time() < end and nonce not in out:
        time.sleep(0.5)
        out = crictl("logs", cid).stdout
    pid = 0
    try:
        pid = int(json.loads(crictl("inspect", "-o", "json", cid).stdout)["info"]["pid"])
    except (ValueError, KeyError, TypeError):
        pass
    return {"pod": sid, "ctr": cid, "pid": pid, "log": out}, None


def up(work):
    bench = bench_dir(work)
    t = {"launcher_sha": sha_file(LAUNCHER), "ctl_sha": sha_file(CTL)}
    rp = find_pid("python3", REGDIR)
    if not rp:
        sys.exit("the registry fixture is not running")
    t["registry_pid"], t["registry_start"] = rp, start_time(rp)
    t["pause_id"] = image_id(PAUSE_REF)
    if not t["pause_id"]:
        sys.exit("the sandbox image %s is not in the node" % PAUSE_REF)
    t["first_build"] = push(work, "initial")
    json.dump(t, open(os.path.join(bench, "truth.json"), "w"))
    print("lab up: node pid %d, registry pid %d at %s, sandbox image %s" % (node_pid(), rp, REG, t["pause_id"][:19]))


def check(work):
    t = load(work)
    msg = problems(t) or identity_problem()
    if not msg and not wait_ready(20):
        msg = "the node does not answer on its CRI socket"
    if not msg and image_id(PAUSE_REF) != t["pause_id"]:
        msg = "the sandbox image of the node is not the one the lab imported"
    if msg:
        print("  -> " + msg)
        sys.exit(1)
    print("lab check ok")


def controls(work):
    t = load(work)
    # 1. the question's error on the node as delivered
    r = pull()
    if r.returncode == 0 or not https_error(r.stderr + r.stdout):
        sys.exit("control 1: the pull over the CRI should fail because it speaks https to a plain-HTTP registry, got rc=%d: %s" % (r.returncode, errtext(r, 400)))
    print("control 1 ok: crictl pull %s fails over https: %s" % (REF, errtext(r, 160)))
    # 2. the asker's try: the entry goes into the generated file, the node is restarted
    gen = read(GENERATED)
    if gen is None or REG in gen:
        sys.exit("control 2: containerd.toml is missing or already mentions the registry")
    with open(GENERATED, "a") as f:
        f.write("\n" + MIRROR)
    r = run([CTL, "restart"], timeout=120)
    if r.returncode != 0 or not wait_ready(90):
        sys.exit("control 2: the node did not come back after 'mk8sctl restart': " + errtext(r))
    if REG in (read(GENERATED) or ""):
        sys.exit("control 2: the entry written into containerd.toml survived the restart (the file is not regenerated)")
    r = pull()
    if r.returncode == 0:
        sys.exit("control 2: the pull works although the entry is gone")
    print("control 2 ok: an entry written into containerd.toml is gone after mk8sctl restart, the pull still fails")
    # 3. a throw-away containerd with the same template and the entry pulls the image
    common = LIB + "/ctl-common"
    sock = common + "/run/containerd.sock"
    shutil.rmtree(common, ignore_errors=True)
    for d in ("run", "var/lib/containerd", "var/log"):
        os.makedirs(os.path.join(common, d), exist_ok=True)
    cfg = os.path.join(common, "containerd.toml")
    open(cfg, "w").write(render(open(TEMPLATE).read() + "\n" + MIRROR, common=common))
    log = open(os.path.join(common, "var/log/containerd.log"), "w")
    p = subprocess.Popen(["env", "-i", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "containerd", "--config", cfg], stdout=log, stderr=log,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        if not wait_sock(sock, 40):
            sys.exit("control 3: the throw-away containerd did not answer: " + short(read(os.path.join(common, "var/log/containerd.log")) or "", 200))
        r = crictl("pull", REF, sock=sock)
        if r.returncode != 0:
            sys.exit("control 3: the throw-away containerd with the registry entry cannot pull: " + errtext(r))
    finally:
        p.terminate()
        try:
            p.wait(20)
        except subprocess.TimeoutExpired:
            p.kill()
        shutil.rmtree(common, ignore_errors=True)
    print("control 3 ok: a containerd with the same template and the registry entry pulls %s" % REF)


if __name__ == "__main__":
    cmd, work = sys.argv[1], sys.argv[2]
    {"up": up, "check": check, "controls": controls}[cmd](work)
