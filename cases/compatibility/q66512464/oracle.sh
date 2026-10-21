#!/bin/bash
set -e

CASE_ID="bench66512464"
WORK_DIR="/tmp/$CASE_ID"

echo "[oracle] the kubelet is the one of the node, restarted, on the remote runtime at containerd's socket; the pod web and a new probe pod run in containerd's CRI and not in Docker; Docker and containerd are untouched and Docker runs a container..."
OUT=$(sudo python3 - "$WORK_DIR" <<'PYEOF' 2>&1
import hashlib
import json
import os
import re
import subprocess
import sys
import time

CASE = "bench66512464"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
OPT = LIB + "/opt/docker"
DOCKER, CTR, DOCKERD, CONTAINERD, RUNC = OPT + "/docker", OPT + "/ctr", OPT + "/dockerd", OPT + "/containerd", OPT + "/runc"
DSOCK, CSOCK = RUN + "/docker.sock", RUN + "/containerd.sock"
KUBELET = LIB + "/opt/kubelet"
KCTL = LIB + "/bin/kubeletctl"
KCFG = LIB + "/kubelet/config.yaml"
KROOT = LIB + "/kubelet/root"
MANI = LIB + "/kubelet/manifests"
NODE = CASE                                  # the kubelet's node name: a static pod called web is web-bench66512464
NS_DOCKER = CASE + "-docker"                 # the containerd namespace of the dockerd; the kubelet's CRI uses k8s.io
IMAGE = CASE + ".local/web:1"


def run(argv, timeout=100):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd="/tmp", stdin=subprocess.DEVNULL)


def short(text, n=170):
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


def comm(pid):
    try:
        return open("/proc/%d/comm" % pid).read().strip()
    except OSError:
        return ""


def cmdargs(pid):
    try:
        return open("/proc/%d/cmdline" % pid, "rb").read().decode("latin-1").split("\0")[:-1]
    except OSError:
        return []


def start_time(pid):
    try:
        return open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def pid_of(path):
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError):
        return 0


def load(work):
    return json.load(open(os.path.join(work, ".bench", "truth.json")))


def docker(*args, timeout=100):
    return run([DOCKER, "-H", "unix://" + DSOCK] + list(args), timeout=timeout)


def ctr(ns, *args, timeout=100):
    return run([CTR, "-a", CSOCK, "-n", ns] + list(args), timeout=timeout)


def crictl(*args, sock=CSOCK, timeout=100):
    return run(["crictl", "-r", "unix://" + sock, "-i", "unix://" + sock, "--timeout", "60s"] + list(args), timeout=timeout)


def flag(args, name):
    """the value of a kubelet flag as the kubelet reads it (the last one wins; --name=value or --name value); None when absent"""
    val = None
    for i, a in enumerate(args):
        if a.startswith("--" + name + "="):
            val = a.split("=", 1)[1]
        elif a == "--" + name and i + 1 < len(args):
            val = args[i + 1]
    return val


def wait_for(fn, timeout, step=1.0):
    end = time.time() + timeout
    while time.time() < end:
        r = fn()
        if r:
            return r
        time.sleep(step)
    return fn()


def lab_problem(t):
    """what the solution must not change: the programs of the node (kubelet, docker, containerd, runc), kubeletctl, and that the dockerd and the containerd of setup are the
    ones that run and answer. Returns the first problem as text, or None."""
    for path, key, what in ((KUBELET, "kubelet_sha", "the kubelet"), (DOCKERD, "dockerd_sha", "dockerd"), (CONTAINERD, "containerd_sha", "containerd"),
                            (RUNC, "runc_sha", "runc"), (KCTL, "kctl_sha", "kubeletctl")):
        if sha_file(path) != t[key]:
            return "%s was changed or replaced (%s)" % (what, path)
    for name, pidf, key, want in (("dockerd", RUN + "/dockerd.pid", "dockerd", "dockerd"), ("containerd", RUN + "/containerd.pid", "containerd", "containerd")):
        pid = pid_of(pidf)
        if not pid or comm(pid) != want or start_time(pid) != t[key + "_start"]:
            return "%s is not the process setup started (it was stopped, restarted or replaced)" % name
    if docker("version", "--format", "{{.Server.Version}}").returncode != 0:
        return "Docker does not answer on %s (the Docker CLI is not usable)" % DSOCK
    if ctr("k8s.io", "version").returncode != 0:
        return "containerd does not answer on %s" % CSOCK
    return None


def docker_control(tag):
    """Docker still runs a container of its own (the CLI is usable): None when it does, else the reason"""
    name = "%s-ctl-%s" % (CASE, tag)
    docker("rm", "-f", name)
    r = docker("run", "-d", "--name", name, "--network", "none", IMAGE, "ctl")
    ok = r.returncode == 0 and name in docker("ps", "--filter", "name=" + name, "--format", "{{.Names}}").stdout
    why = short(r.stderr or r.stdout)
    docker("rm", "-f", name)
    return None if ok else why


def sandbox_control(work, tag):
    """containerd's CRI runs a pod sandbox on this host (what a kubelet that uses it needs): None when it does, else the reason"""
    cfg = os.path.join(work, ".bench", "sandbox-%s.json" % tag)
    json.dump({"metadata": {"name": "ctl-" + tag, "namespace": "default", "uid": "ctl-" + tag, "attempt": 1},
               "linux": {"security_context": {"namespace_options": {"network": 2}}}}, open(cfg, "w"))
    r = crictl("runp", cfg)
    pod = r.stdout.strip().splitlines()[-1] if r.returncode == 0 and r.stdout.strip() else ""
    ok = bool(pod) and "Ready" in crictl("pods", "--id", pod).stdout
    why = short(r.stderr or r.stdout)
    if pod:
        crictl("stopp", pod)
        crictl("rmp", pod)
    os.remove(cfg)
    return None if ok else why

work = sys.argv[1]
t = load(work)
PROBE = "probe"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def kubelet_log():
    lines = [ln for ln in (read(RUN + "/kubelet.log") or "").splitlines() if re.match(r"^[EF]\d{4} ", ln)]
    return short(lines[-1] if lines else "(no error line in the log)", 230)


def cri_containers():
    """running containers of containerd's CRI: [(pod name, container name)]"""
    try:
        d = json.loads(crictl("ps", "-o", "json").stdout or "{}")
    except ValueError:
        return []
    return [(c.get("labels", {}).get("io.kubernetes.pod.name"), c.get("labels", {}).get("io.kubernetes.container.name"))
            for c in d.get("containers", []) if c.get("state") == "CONTAINER_RUNNING"]


def shim_namespaces(nonce):
    """the containerd namespaces of the shims whose container runs the workload with this argument"""
    out = set()
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        a = cmdargs(int(d))
        if len(a) >= 2 and a[-1] == nonce and a[0].endswith("web"):
            try:
                ppid = int(open("/proc/%s/stat" % d).read().rsplit(")", 1)[1].split()[1])
            except (OSError, ValueError, IndexError):
                continue
            pa = cmdargs(ppid)
            if "-address" in pa and pa[pa.index("-address") + 1] == CSOCK and "-namespace" in pa:
                out.add(pa[pa.index("-namespace") + 1])
    return out


p = lab_problem(t)
if p:
    fail(p)
kp = pid_of(RUN + "/kubelet.pid")
if not kp or comm(kp) != "kubelet":
    fail("the kubelet does not run (the node's kubelet has to run, started with kubeletctl); its last error: " + kubelet_log())
if os.path.realpath("/proc/%d/exe" % kp) != KUBELET:
    fail("the process in %s/kubelet.pid is not the kubelet of the node" % RUN)
if start_time(kp) == t["kubelet_start_pre"]:
    fail("the kubelet was not restarted: it reads its flags only when it starts (it still runs as before, on Docker)")
args = cmdargs(kp)
rt, ep = flag(args, "container-runtime"), flag(args, "container-runtime-endpoint")
if rt != "remote":
    fail("the running kubelet has --container-runtime=%s: with the docker runtime (the default of 1.23) it starts dockershim and talks to Docker, not to containerd" % (rt or "(not set)"))
sock = (ep or "").replace("unix://", "")
if sock == DSOCK:
    fail("the kubelet's runtime endpoint is Docker's API socket (%s): it is not a CRI endpoint, containerd's is %s" % (DSOCK, CSOCK))
if sock != CSOCK:
    fail("the kubelet's runtime endpoint is %s, containerd's CRI socket is %s" % (ep or "(not set)", CSOCK))

# the pod web, which the kubelet started on Docker, is now run by the kubelet through containerd
def web_running():
    return ("web-" + NODE, "web") in cri_containers()


if not wait_for(web_running, 120):
    names = docker("ps", "--format", "{{.Names}}").stdout.split()
    fail("the pod web does not run in containerd's CRI (crictl ps: %s); the kubelet's last error: %s" % (short(str(cri_containers()), 120), kubelet_log()))
nonce = t["web_nonce"]
if "k8s.io" not in wait_for(lambda: shim_namespaces(nonce), 20):
    fail("the process of the pod web is not under a containerd shim of the namespace k8s.io (the containerd of the node)")

# a pod that did not exist before: a new static pod must be created by the kubelet through containerd and never through Docker
probe_nonce = "probe" + os.urandom(5).hex()
pm = MANI + "/%s.yaml" % PROBE
web_yaml = read(MANI + "/web.yaml")
if not web_yaml:
    fail("the manifest %s/web.yaml is gone" % MANI)
try:
    open(pm, "w").write(web_yaml.replace("name: web", "name: " + PROBE, 1).replace(t["web_nonce"], probe_nonce))
    if not wait_for(lambda: ("%s-%s" % (PROBE, NODE), "web") in cri_containers(), 90):
        fail("a new static pod (probe) did not run in containerd's CRI within 90 s; the kubelet's last error: " + kubelet_log())
    if "k8s.io" not in wait_for(lambda: shim_namespaces(probe_nonce), 20):
        fail("the process of the probe pod is not under a containerd shim of the namespace k8s.io")
    dnames = docker("ps", "-a", "--format", "{{.Names}}").stdout.split()
    if any(PROBE in n and n.startswith("k8s_") for n in dnames):
        fail("the probe pod was also created in Docker: " + short(" ".join(dnames)))
finally:
    try:
        os.remove(pm)
    except OSError:
        pass
    wait_for(lambda: not [c for c in cri_containers() if c[0] == "%s-%s" % (PROBE, NODE)], 60)
why = docker_control("post")
if why:
    fail("Docker cannot run a container any more: " + why)
print("[oracle] PASS: the kubelet (restarted, --container-runtime=remote at %s) runs the pods web and probe in containerd's CRI (shims of the namespace k8s.io), nothing new in Docker, and Docker still runs containers" % CSOCK)
PYEOF
) || { echo "$OUT"; exit 1; }
echo "$OUT"
