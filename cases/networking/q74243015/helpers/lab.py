#!/usr/bin/env python3
"""lab.py up|check|controls WORK : the record of what is true about the lab of q74243015 (run as root; verify.py uses it as a module).

The lab: a private CRI-O (systemd unit bench74243015-crio.service, config /etc/bench74243015/crio.conf, CRI socket /run/bench74243015/crio.sock, an EMPTY image store) whose
pause_image is registry.bench74243015.test:35743/pause:3.6. The registry (registry.py, 127.0.0.2:35743, HTTPS with a private CA) serves only that repository and resets every
connection that does not come from the lab's proxy (source address 127.0.0.7): this is the controlled egress. The proxy (proxy.py, 127.0.0.1:35744) tunnels CONNECT to the registry
and to nothing else. The CRI-O service has no proxy variable in its environment, so a new sandbox cannot pull the pause image.

  up        (after setup.sh started the service) waits for the service and writes WORK/.bench/truth.json: the digests of the pause image (manifest, config, layer, from mkoci.py),
            the sha256 of the pause program, hashes of the config, of the registry configuration of the host and of the blob store, the identity (start time + command line) of the
            registry and the proxy, and the command line of the service.
  check     the lab is as it was: config, drop-in directory, registry configuration, certificates, blob store, hosts line, the registry and the proxy are the same processes.
  controls  the control of precondition.sh: the service has no proxy variable, a new sandbox on the empty store fails twice while pulling the pause image, and a throw-away CRI-O
            with the same configuration but HTTPS_PROXY set creates the sandbox (so the lab can be solved).

Used by verify.py: load(), problems(), crictl(), service_pid(), proc_env(), wipe(), runp(), tail_log()."""
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time

CASE = "bench74243015"
UNIT = CASE + "-crio.service"
HOST = "registry.bench74243015.test"
PORT = 35743
PROXY_URL = "http://127.0.0.1:35744"
SRC_IP = "127.0.0.7"
PAUSE_REF = "%s:%d/pause:3.6" % (HOST, PORT)
SOCK = "/run/bench74243015/crio.sock"
CONF = "/etc/bench74243015/crio.conf"
CONFD = "/etc/bench74243015/crio.conf.d"
ENVFILE = "/etc/default/bench74243015-crio"
CERTS = "/etc/containers/certs.d/%s:%d" % (HOST, PORT)
REGCONF = "/etc/containers/registries.conf"
REGCONFD = "/etc/containers/registries.conf.d"
POD_CGROUP = "/bench74243015-pods"
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


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


def listing(d):
    try:
        return sorted(os.listdir(d))
    except OSError:
        return None


def tree_sha(d):
    """one hash for the names and contents of everything below D (None if D does not exist)"""
    if not os.path.isdir(d):
        return None
    h = hashlib.sha256()
    for root, dirs, files in sorted(os.walk(d)):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            h.update(os.path.relpath(p, d).encode() + b"\0" + (sha_file(p) or "").encode() + b"\0")
    return h.hexdigest()


def run(argv, timeout=100, env=None):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env, cwd="/tmp")


def crictl(*args, timeout=100, sock=SOCK):
    return run(["crictl", "-r", "unix://" + sock, "-i", "unix://" + sock, "--timeout", "60s"] + list(args), timeout=timeout)


def systemctl(*args, timeout=120):
    return run(["systemctl"] + list(args), timeout=timeout)


def service_pid():
    r = systemctl("show", "-p", "MainPID", "--value", UNIT)
    try:
        return int(r.stdout.strip())
    except ValueError:
        return 0


def need_daemon_reload():
    return systemctl("show", "-p", "NeedDaemonReload", "--value", UNIT).stdout.strip() == "yes"


def proc_env(pid):
    try:
        raw = open("/proc/%d/environ" % pid, "rb").read().split(b"\0")
    except OSError:
        return {}
    return dict(x.decode("latin-1").split("=", 1) for x in raw if b"=" in x)


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
    """the pid of the lab's python helper SCRIPT (registry.py / proxy.py) started by setup.sh"""
    for d in os.listdir("/proc"):
        if d.isdigit():
            c = proc_cmdline(int(d)) or ""
            if re.search(r"python3? .*/%s " % re.escape(script), c) and CASE in c:
                return int(d)
    return 0


def wait_sock(sock=SOCK, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(sock) and crictl("version", sock=sock).returncode == 0:
            return True
        time.sleep(0.4)
    return False


def wipe(sock=SOCK):
    """stop and remove every sandbox of the service and remove every image; returns the names of the images that were in the store"""
    for p in crictl("pods", "-q", sock=sock).stdout.split():
        crictl("stopp", p, sock=sock)
        crictl("rmp", p, sock=sock)
    imgs = []
    r = crictl("images", "-o", "json", sock=sock)
    try:
        for i in json.loads(r.stdout).get("images", []):
            imgs += i.get("repoTags") or i.get("repoDigests") or [i["id"]]
    except ValueError:
        pass
    crictl("rmi", "--all", sock=sock)
    return imgs


def runp(work, sock=SOCK):
    """a brand-new sandbox in the host's network namespace (no CNI): (returncode, pod id or the error text)"""
    out = os.path.join(work, "out")
    os.makedirs(out, exist_ok=True)
    os.chmod(out, 0o755)
    name = "p" + secrets.token_hex(4)
    logs = os.path.join(out, "logs-" + name)
    os.makedirs(logs, exist_ok=True)
    pod = {"metadata": {"name": name, "namespace": "default", "uid": secrets.token_hex(8), "attempt": 1}, "log_directory": logs,
           "linux": {"cgroup_parent": POD_CGROUP, "security_context": {"namespace_options": {"network": 2}}}}
    pj = os.path.join(out, name + ".json")
    json.dump(pod, open(pj, "w"))
    r = crictl("runp", pj, timeout=120, sock=sock)
    if r.returncode == 0:
        return 0, r.stdout.strip().split("\n")[-1]
    return r.returncode, (r.stderr or r.stdout).strip().split("\n")[-1]


def short_error(text, n=150):
    """the reason in the error of runp, without the names that every error repeats: 'Get "http://HOST:PORT/v2/": read tcp ...: connection reset by peer'"""
    t = text.replace('\\"', '"').split("desc = ", 1)[-1].split("; artifact err", 1)[0]
    t = re.sub(r'^creating pod sandbox with name "[^"]*": ', "", t)
    t = t.replace("unable to pull image or OCI artifact: pull image err: ", "")
    t = re.sub(r"^initializing source \S+: pinging container registry \S+: ", "", t)
    return t[:n]


def tail_log(path, offset):
    """the JSON lines the lab's registry or proxy wrote after byte OFFSET of PATH"""
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


def problems(t):
    """what changed in the lab that the solution was not allowed to change (a list of short texts; empty = as it was)"""
    p = []
    if sha_file(CONF) != t["conf_sha"]:
        p.append("the CRI-O configuration %s was changed (the pause image and the rest stay as they are)" % CONF)
    if listing(CONFD) != t["confd"]:
        p.append("the drop-in directory %s of the configuration was changed" % CONFD)
    if sha_file(REGCONF) != t["regconf_sha"] or listing(REGCONFD) != t["regconfd"]:
        p.append("the registry configuration of the host (/etc/containers/registries.conf*) was changed: the pause source stays as it is")
    if tree_sha(CERTS) != t["certs_sha"]:
        p.append("the certificates of the lab's registry (%s) were changed" % CERTS)
    if tree_sha(t["blobs"]) != t["blobs_sha"]:
        p.append("the pause image in the lab's registry was changed")
    if t["hosts_line"] not in open("/etc/hosts").read().splitlines():
        p.append("the line of /etc/hosts for %s was changed" % HOST)
    for name, key in (("registry", "registry"), ("proxy", "proxy")):
        pid, start = t[key]["pid"], t[key]["start"]
        if proc_start(pid) != start or "%s.py" % name not in (proc_cmdline(pid) or ""):
            p.append("the lab's %s was stopped or replaced (it is the egress control; it stays as it is)" % name)
    return p


def up(work):
    bench, tp = paths(work)
    oci = json.load(open(os.path.join(bench, "oci.json")))
    if not wait_sock():
        raise SystemExit("the CRI-O service does not answer on %s" % SOCK)
    pid = service_pid()
    reg, prx = find_proc("registry.py"), find_proc("proxy.py")
    if not (pid and reg and prx):
        raise SystemExit("the service (%s), the registry (%s) or the proxy (%s) is not running" % (pid, reg, prx))
    if crictl("images", "-q").stdout.strip() or crictl("pods", "-q").stdout.strip():
        raise SystemExit("the store of the service is not empty")
    truth = {"manifest": oci["manifest"], "config": oci["config"], "layer": oci["layer"], "tag": oci["tag"],
             "pause_sha": sha_file(os.path.join(bench, "pause")), "blobs": os.path.join(bench, "registry"),
             "blobs_sha": tree_sha(os.path.join(bench, "registry")), "conf_sha": sha_file(CONF), "confd": listing(CONFD),
             "regconf_sha": sha_file(REGCONF), "regconfd": listing(REGCONFD), "certs_sha": tree_sha(CERTS),
             "hosts_line": open(os.path.join(bench, "hosts_line")).read().strip(),
             "registry": {"pid": reg, "start": proc_start(reg)}, "proxy": {"pid": prx, "start": proc_start(prx)},
             "service_cmdline": proc_cmdline(pid), "registry_log": os.path.join(bench, "registry.log"), "proxy_log": os.path.join(bench, "proxy.log")}
    with open(tp + ".tmp", "w") as f:
        json.dump(truth, f)
    os.replace(tp + ".tmp", tp)


def check(work):
    t = load(work)
    pr = problems(t)
    if pr:
        raise SystemExit(pr[0])
    if systemctl("is-active", UNIT).stdout.strip() != "active" or not crictl("version").returncode == 0:
        raise SystemExit("the CRI-O service is not active")


def throwaway_instance(work, t):
    """a second CRI-O with the configuration of the service (other directories) and HTTPS_PROXY set: the proof that the lab can be solved. Returns the sandbox state."""
    conf = open(CONF).read().replace("/var/lib/bench74243015", "/var/lib/bench74243015-ctl").replace("/run/bench74243015", "/run/bench74243015-ctl")
    for d in ("/var/lib/bench74243015-ctl", "/run/bench74243015-ctl"):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
    cpath = "/var/lib/bench74243015-ctl/crio.conf"
    open(cpath, "w").write(conf)
    sock = "/run/bench74243015-ctl/crio.sock"
    cmd = t["service_cmdline"].split()
    exe = cmd[0]
    env = {"PATH": PATH, "HTTPS_PROXY": PROXY_URL, "NO_PROXY": "localhost,127.0.0.1"}
    log = open("/var/lib/bench74243015-ctl/crio.log", "w")
    proc = subprocess.Popen([exe, "--config", cpath, "--config-dir", CONFD], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    try:
        if not wait_sock(sock):
            raise SystemExit("the throw-away CRI-O did not start: %s" % open("/var/lib/bench74243015-ctl/crio.log").read().strip().split("\n")[-1][-160:])
        rc, pod = runp(work, sock=sock)
        if rc != 0:
            raise SystemExit("with HTTPS_PROXY set the sandbox is not created either: %s" % pod)
        st = json.loads(crictl("inspectp", pod, sock=sock).stdout)["status"]["state"]
        crictl("stopp", pod, sock=sock)
        crictl("rmp", pod, sock=sock)
        crictl("rmi", "--all", sock=sock)
        return st
    finally:
        proc.terminate()
        try:
            proc.wait(15)
        except subprocess.TimeoutExpired:
            proc.kill()
        subprocess.run("for m in $(awk '{print $2}' /proc/mounts | grep -e bench74243015-ctl | sort -r); do umount \"$m\" 2>/dev/null; done", shell=True)
        shutil.rmtree("/var/lib/bench74243015-ctl", ignore_errors=True)
        shutil.rmtree("/run/bench74243015-ctl", ignore_errors=True)


def controls(work):
    t = load(work)
    pid = service_pid()
    env = proc_env(pid)
    pv = {k: v for k, v in env.items() if k.lower().endswith("_proxy")}
    if not pid or pv:
        raise SystemExit("the service must run without proxy variables (pid %s, %s)" % (pid, pv))
    wipe()
    for i in (1, 2):
        rc, err = runp(work)
        if rc == 0:
            raise SystemExit("a sandbox was created on the empty store without a proxy")
        if HOST not in err or "pinging container registry" not in err:
            raise SystemExit("runp failed, but not on the pull of the pause image: %s" % short_error(err))
    print("  -> OK control 1: the service (pid %d) has no proxy variable; on the empty store runp fails twice: %s" % (pid, short_error(err)))
    st = throwaway_instance(work, t)
    if st != "SANDBOX_READY":
        raise SystemExit("with HTTPS_PROXY set the sandbox is %s" % st)
    print("  -> OK control 2: a throw-away CRI-O with HTTPS_PROXY=%s and the same configuration creates the sandbox (%s)" % (PROXY_URL, st))


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "check": check, "controls": controls}[cmd](work)
