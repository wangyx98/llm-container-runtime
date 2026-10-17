#!/usr/bin/env python3
"""lab.py up|check|controls WORK : the lab of q72094271 (run as root by setup.sh, precondition.sh and, as a module, by verify.py).

The node: a private containerd, the systemd service bench72094271-containerd.service (unit file with LimitCORE=infinity, as the upstream containerd.service has it), CRI socket
/run/bench72094271/containerd.sock, a sandbox image and one probe image imported offline into the namespace k8s.io, and a kernel.core_pattern that the lab fixed to a FILE pattern
(core.%e.%P in the working directory of the dumping process; a piped handler would ignore RLIMIT_CORE).

  up        imports the images, records what is true (digests of the images, the lab's core_pattern, the probe program) in WORK/.bench/truth.json
  check     the lab is as the record says (images, core_pattern) and the service is the process that answers on the socket: prints the first problem, exit 1
  controls  the positive and the negative control: new containers of the unchanged lab have core=unlimited, an aborted process leaves a core file, a process that limited itself to 0 leaves none

observe() makes a new pod (own random name and uid), a long-running container and a container that aborts, and returns what was measured; verify.py judges it."""
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time

CASE = "bench72094271"
UNIT = CASE + "-containerd.service"
SOCK = "/run/%s/containerd.sock" % CASE
TOML = "/etc/%s/containerd.toml" % CASE
CORES = "/var/lib/%s/cores" % CASE
POD_CGROUP = "/%s-pods" % CASE
PROBE_REF = CASE + ".local/probe:1"
PAUSE_REF = CASE + ".local/pause:1"
CORE_PATTERN = "core.%e.%P"


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json")


def load(work):
    return json.load(open(paths(work)[1]))


def run(argv, timeout=100):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp")


def crictl(*args, timeout=100):
    return run(["crictl", "-r", "unix://" + SOCK, "-i", "unix://" + SOCK, "--timeout", "60s"] + list(args), timeout=timeout)


def systemctl(*args, timeout=120):
    return run(["systemctl"] + list(args), timeout=timeout)


def service_pid():
    try:
        return int(systemctl("show", "-p", "MainPID", "--value", UNIT).stdout.strip())
    except ValueError:
        return 0


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


def containerd_pid():
    """the pid of the containerd that runs with the lab's configuration file (0 if there is none)"""
    for d in os.listdir("/proc"):
        if d.isdigit() and comm(int(d)) == "containerd" and TOML in cmdline(int(d)):
            return int(d)
    return 0


def core_limits(pid):
    """(soft, hard) of RLIMIT_CORE of a process, as /proc/PID/limits says: strings ('0', 'unlimited', ...); None when the process is gone"""
    try:
        for line in open("/proc/%d/limits" % pid):
            if line.startswith("Max core file size"):
                f = line.split()
                return f[4], f[5]
    except OSError:
        return None
    return None


def sha_file(p):
    try:
        return hashlib.sha256(open(p, "rb").read()).hexdigest()
    except OSError:
        return None


def core_pattern():
    return open("/proc/sys/kernel/core_pattern").read().strip()


def wait_sock(timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(SOCK) and crictl("version").returncode == 0:
            return True
        time.sleep(0.4)
    return False


def wait_ready(timeout=60):
    """a restarted service answers late: `systemctl restart` returns when the process is started, not when containerd has opened its socket and loaded its images.
    Waits until the CRI answers and both images of the lab are listed again; returns False when that does not happen in time."""
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(SOCK) and crictl("version").returncode == 0 and image_id(PROBE_REF) and image_id(PAUSE_REF):
            return True
        time.sleep(0.5)
    return False


def wipe_pods():
    for p in crictl("pods", "-q").stdout.split():
        crictl("stopp", p)
        crictl("rmp", p)


def image_id(ref):
    r = crictl("inspecti", "-o", "json", ref)
    try:
        return json.loads(r.stdout)["status"]["id"]
    except (ValueError, KeyError):
        return None


def short(text, n=150):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[:n - 3] + "..."


class Fail(Exception):
    pass


def observe(work, tag, crash_mode="abort", exec_mode="abort"):
    """a new pod with a running container (main) and a container that aborts (crash); exec probes in main. Returns a dict of measurements; raises Fail with a short text when the node cannot do it."""
    n = secrets.token_hex(4)
    nonce = secrets.token_hex(6)
    out = os.path.join(work, "out", tag + n)
    cores = os.path.join(CORES, tag + n)
    os.makedirs(out, exist_ok=True)
    os.makedirs(cores, exist_ok=True)
    os.chmod(cores, 0o755)
    pod_cfg = os.path.join(out, "pod.json")
    json.dump({"metadata": {"name": "%s-%s%s" % (CASE, tag, n), "namespace": "default", "attempt": 1, "uid": "u-" + secrets.token_hex(8)},
               "log_directory": out,
               "linux": {"cgroup_parent": POD_CGROUP, "security_context": {"namespace_options": {"network": 2, "pid": 0}}}}, open(pod_cfg, "w"))
    r = crictl("runp", pod_cfg)
    for _ in range(2):      # a node that has just restarted can refuse a first request
        if r.returncode == 0:
            break
        time.sleep(3)
        r = crictl("runp", pod_cfg)
    if r.returncode != 0:
        raise Fail("a new pod sandbox cannot be created: " + short(r.stderr.splitlines()[-1] if r.stderr else ""))
    pod = r.stdout.strip().splitlines()[-1]
    obs = {"tag": tag, "cores": cores, "nonce": nonce}
    try:
        def make(name, args):
            cfg = os.path.join(out, name + ".json")
            json.dump({"metadata": {"name": name}, "image": {"image": PROBE_REF}, "args": args, "working_dir": "/cores",
                       "mounts": [{"container_path": "/cores", "host_path": cores, "readonly": False}], "log_path": name + ".log", "linux": {}}, open(cfg, "w"))
            c = crictl("create", pod, cfg, pod_cfg)
            if c.returncode != 0:
                raise Fail("a container cannot be created: " + short(c.stderr.splitlines()[-1] if c.stderr else ""))
            cid = c.stdout.strip().splitlines()[-1]
            s = crictl("start", cid)
            if s.returncode != 0:
                raise Fail("a container cannot be started: " + short(s.stderr.splitlines()[-1] if s.stderr else ""))
            return cid

        def info(cid):
            try:
                return json.loads(crictl("inspect", "-o", "json", cid).stdout)
            except ValueError:
                return {}

        def core_files(label):
            return sorted(f for f in os.listdir(cores) if f.startswith("core.%s." % label))

        def limits_file(label):
            try:
                return open(os.path.join(cores, label + ".limits")).read().split()
            except OSError:
                return None

        main = make("main", ["serve", nonce])
        obs["main_pid"] = int(info(main).get("info", {}).get("pid", 0))
        obs["main_limits"] = core_limits(obs["main_pid"])
        obs["main_exe_sha"] = sha_file("/proc/%d/exe" % obs["main_pid"])
        e = crictl("exec", main, "/probe", "limits", nonce)
        m = re.search(r"limits nonce=(\S+) pid=(\d+) soft=(\S+) hard=(\S+)", e.stdout)
        obs["exec_limits"] = (m.group(3), m.group(4)) if m and m.group(1) == nonce else None
        elabel = "ex" + n
        e = crictl("exec", main, "/probe", exec_mode, nonce, elabel)
        time.sleep(1)
        obs["exec_abort_rc"] = e.returncode
        obs["exec_abort_limits"] = limits_file(elabel)
        obs["exec_abort_cores"] = core_files(elabel)
        clabel = "cr" + n
        crash = make("crash", [crash_mode, nonce, clabel])
        st = {}
        for _ in range(60):
            st = info(crash).get("status", {})
            if st.get("state") == "CONTAINER_EXITED":
                break
            time.sleep(0.5)
        time.sleep(1)
        obs["crash_exit"] = st.get("exitCode")
        obs["crash_limits"] = limits_file(clabel)
        obs["crash_cores"] = core_files(clabel)
        obs["core_sizes"] = [os.path.getsize(os.path.join(cores, f)) for f in obs["exec_abort_cores"] + obs["crash_cores"]]
    finally:
        crictl("stopp", pod)
        crictl("rmp", pod)
    return obs


def problems(work):
    """the first thing in the lab that is not as the record says, or ''"""
    t = load(work)
    if core_pattern() != CORE_PATTERN:
        return "kernel.core_pattern was changed to '%s' (the lab fixed it to '%s')" % (core_pattern(), CORE_PATTERN)
    if t["probe_sha"] != sha_file(os.path.join(paths(work)[0], "probe-bin")):
        return "the probe program of the lab was changed"
    if not wait_ready():
        return "containerd does not answer on %s (or has lost the images of the lab) 60 seconds after the last change" % SOCK
    for ref in (PROBE_REF, PAUSE_REF):
        if image_id(ref) != t["images"][ref]:
            return "the image %s is not the one the lab imported" % ref
    svc, ctd = service_pid(), containerd_pid()
    if not svc or svc != ctd:
        return "the containerd that answers (pid %s) is not the main process of %s (pid %s)" % (ctd or "none", UNIT, svc or "none")
    return ""


def up(work):
    bench, truth = paths(work)
    if not wait_sock():
        sys.exit("the node's containerd does not answer on " + SOCK)
    ids = {}
    for ref, f in ((PAUSE_REF, "pause.tar"), (PROBE_REF, "probe.tar")):
        r = run(["ctr", "-a", SOCK, "-n", "k8s.io", "images", "import", os.path.join(bench, f)])
        if r.returncode != 0:
            sys.exit("the image %s was not imported: %s" % (ref, short(r.stderr)))
        ids[ref] = image_id(ref)
    json.dump({"probe_sha": sha_file(os.path.join(bench, "probe-bin")), "images": ids, "core_pattern": core_pattern(), "service_pid": service_pid()}, open(truth, "w"))
    os.chmod(truth, 0o600)


def controls(work):
    """exit 1 with one FAIL line, or print what was seen"""
    bad = problems(work)
    if bad:
        sys.exit("FAIL: " + bad)
    pid = service_pid()
    lim = core_limits(pid)
    if lim != ("unlimited", "unlimited"):
        sys.exit("FAIL: the containerd service has core limit %s (setup made it unlimited)" % (lim,))
    o = observe(work, "pre")
    if o["main_limits"] != ("unlimited", "unlimited") or o["exec_limits"] != ("unlimited", "unlimited"):
        sys.exit("FAIL: a new container has core limit main=%s exec=%s (it must be unlimited here)" % (o["main_limits"], o["exec_limits"]))
    if not o["crash_cores"] or not o["exec_abort_cores"] or not all(s > 0 for s in o["core_sizes"]):
        sys.exit("FAIL: an aborted process left no core file (main: %s, exec: %s): the kernel does not write cores here" % (o["crash_cores"], o["exec_abort_cores"]))
    print("  -> service containerd (pid %d): core unlimited/unlimited; a new container: main %s, exec %s; SIGABRT leaves %s and %s" % (
        pid, "/".join(o["main_limits"]), "/".join(o["exec_limits"]), o["crash_cores"][0], o["exec_abort_cores"][0]))
    z = observe(work, "ctl0", crash_mode="abort0", exec_mode="abort0")
    if z["crash_cores"] or z["exec_abort_cores"] or z["crash_exit"] != 134:
        sys.exit("FAIL: a process that limited itself to core 0 still left a core file or did not abort (exit %s, files %s %s)" % (z["crash_exit"], z["crash_cores"], z["exec_abort_cores"]))
    print("  -> control: a process that sets its own core limit to 0 aborts (exit 134) and leaves no core file")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("up", "check", "controls"):
        sys.exit("usage: lab.py up|check|controls WORK")
    w = sys.argv[2]
    if sys.argv[1] == "up":
        up(w)
    elif sys.argv[1] == "check":
        b = problems(w)
        if b:
            print("FAIL: " + b)
            sys.exit(1)
    else:
        controls(w)
