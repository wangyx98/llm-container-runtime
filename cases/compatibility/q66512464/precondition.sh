#!/bin/bash
set -e

CASE_ID="bench66512464"
WORK_DIR="/tmp/$CASE_ID"

echo "[precondition] the node as recorded; the kubelet runs on Docker (dockershim); containerd runs next to it with nothing of the kubelet; controls: containerd's CRI can run a pod sandbox, Docker runs a container..."
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


def fail(msg):
    print("[precondition] FAIL: " + msg)
    sys.exit(1)


p = lab_problem(t)
if p:
    fail(p)
kp = pid_of(RUN + "/kubelet.pid")
if not kp or comm(kp) != "kubelet" or os.path.realpath("/proc/%d/exe" % kp) != KUBELET:
    fail("the kubelet of setup does not run")
args = cmdargs(kp)
rt, ep = flag(args, "container-runtime"), flag(args, "container-runtime-endpoint")
if rt not in (None, "docker"):
    fail("the kubelet does not start with the docker runtime (--container-runtime=%s)" % rt)
if not ep or ep.replace("unix://", "") != RUN + "/dockershim.sock":
    fail("the kubelet's endpoint is not the dockershim socket of the lab (%s)" % ep)
if flag(args, "docker-endpoint") != "unix://" + DSOCK:
    fail("the kubelet does not talk to the dockerd of the lab")
if not os.path.exists(RUN + "/dockershim.sock"):
    fail("the kubelet does not serve a dockershim socket")
names = docker("ps", "--format", "{{.Names}}").stdout.split()
for want in ("k8s_web_web-" + NODE, "k8s_POD_web-" + NODE):
    if not any(n.startswith(want) for n in names):
        fail("Docker has no container %s*: the pod web does not run through Docker (%s)" % (want, short(" ".join(names))))
r = crictl("version")
if r.returncode != 0 or "containerd" not in r.stdout:
    fail("containerd's CRI does not answer: " + short(r.stderr + r.stdout))
pods = crictl("pods", "-q").stdout.split()
if pods:
    fail("containerd's CRI already has pods of its own: " + short(" ".join(pods)))
if ctr("k8s.io", "containers", "ls", "-q").stdout.split():
    fail("the namespace k8s.io of containerd already has containers")
if len(ctr(NS_DOCKER, "containers", "ls", "-q").stdout.split()) < 2:
    fail("Docker's containers are not in the namespace %s of containerd" % NS_DOCKER)
why = sandbox_control(work, "pre")
if why:
    fail("control: containerd's CRI cannot run a pod sandbox on this host: " + why)
why = docker_control("pre")
if why:
    fail("control: Docker cannot run a container: " + why)
t["kubelet_start_pre"] = start_time(kp)
t["kubelet_pid_pre"] = kp
json.dump(t, open(os.path.join(work, ".bench", "truth.json"), "w"))
print("[precondition] OK: the kubelet (pid %d) runs on Docker, which is in front of containerd; the pod web is in Docker; containerd's CRI is empty and runs a sandbox; Docker runs a container" % kp)
PYEOF
) || { echo "$OUT"; exit 1; }
echo "$OUT"
