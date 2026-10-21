#!/bin/bash
set -e

CASE_ID="bench53435138"
WORK_DIR="/tmp/$CASE_ID"

echo "[precondition] the node as recorded; the pod jenkins mounts containerd's socket as /var/run/docker.sock and docker fails on it; controls: no dockerd on the node, and a pod with its own dockerd builds and runs a job here..."
OUT=$(sudo python3 - "$WORK_DIR" <<'PYEOF' 2>&1
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

CASE = "bench53435138"
LIB = "/var/lib/" + CASE
RUN = "/run/" + CASE
OPT = LIB + "/opt/docker"
CTR, CONTAINERD, RUNC = OPT + "/ctr", OPT + "/containerd", OPT + "/runc"
CSOCK = RUN + "/containerd.sock"
KUBELET = LIB + "/opt/kubelet"
KCTL = LIB + "/bin/kubeletctl"
KROOT = LIB + "/kubelet/root"
MANI = LIB + "/kubelet/manifests"
WS = LIB + "/workspace"                      # the Jenkins workspace: the host side of /home/jenkins/agent
WS_IN = "/home/jenkins/agent"
WORK = sys.argv[1] if len(sys.argv) > 1 else "/tmp/" + CASE
NODE = CASE
POD = "jenkins-" + NODE                      # a static pod called jenkins is jenkins-<node>


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


def ppid(pid):
    try:
        return int(open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[1])
    except (OSError, IndexError, ValueError):
        return 0


def pid_of(path):
    try:
        return int(open(path).read().strip())
    except (OSError, ValueError):
        return 0


def load(work):
    return json.load(open(os.path.join(work, ".bench", "truth.json")))


def ctr(ns, *args, timeout=100):
    return run([CTR, "-a", CSOCK, "-n", ns] + list(args), timeout=timeout)


def crictl(*args, timeout=100):
    return run(["crictl", "-r", "unix://" + CSOCK, "-i", "unix://" + CSOCK, "--timeout", "%ds" % max(timeout - 10, 5)] + list(args), timeout=timeout)


def cri_json(*args, timeout=100):
    try:
        return json.loads(crictl(args[0], "-o", "json", *args[1:], timeout=timeout).stdout or "{}")
    except ValueError:
        return {}


def wait_for(fn, timeout, step=1.0):
    end = time.time() + timeout
    while time.time() < end:
        r = fn()
        if r:
            return r
        time.sleep(step)
    return fn()


def lab_problem(t):
    """what the solution must not change: the programs of the node (kubelet, containerd, runc), kubeletctl, the three images, and that the containerd of setup runs and
    answers and the kubelet runs. Returns the first problem as text, or None."""
    for path, key, what in ((KUBELET, "kubelet_sha", "the kubelet"), (CONTAINERD, "containerd_sha", "containerd"), (RUNC, "runc_sha", "runc"), (KCTL, "kctl_sha", "kubeletctl")):
        if sha_file(path) != t[key]:
            return "%s was changed or replaced (%s)" % (what, path)
    pid = pid_of(RUN + "/containerd.pid")
    if not pid or comm(pid) != "containerd" or start_time(pid) != t["containerd_start"]:
        return "containerd is not the process setup started (it was stopped, restarted or replaced)"
    if ctr("k8s.io", "version").returncode != 0:
        return "containerd does not answer on " + CSOCK
    kp = pid_of(RUN + "/kubelet.pid")
    if not kp or comm(kp) != "kubelet" or os.path.realpath("/proc/%d/exe" % kp) != KUBELET:
        return "the kubelet of the node does not run (the pods are its work): " + short(" ".join((read(RUN + "/kubelet.log") or "").splitlines()[-1:]), 200)
    have = {i["id"] for i in cri_json("images").get("images", [])}
    for tag, iid in t["images"].items():
        if iid not in have:
            return "the image %s is no longer in containerd (the images of the node must stay)" % tag
    return None


def pod_state(name=POD):
    """(sandbox id, {container name: container id}) of the newest Ready sandbox of the pod; the containers are the running ones"""
    pods = [p for p in cri_json("pods", "--name", name, "--state", "ready").get("items", []) if p.get("metadata", {}).get("name") == name]
    if not pods:
        return None, {}
    pods.sort(key=lambda p: int(p.get("createdAt", 0)))
    sid = pods[-1]["id"]
    cs = cri_json("ps", "--pod", sid, "--state", "running").get("containers", [])
    return sid, {c["metadata"]["name"]: c["id"] for c in cs}


def cexec(cid, argv, timeout=180):
    return crictl("exec", cid, *argv, timeout=timeout)


def run_job(cid, nonce, tag, hold=False):
    """what a Jenkins job does in the agent container: a build context in the workspace, `docker build` (the base is scratch: a cold build, no registry), `docker run`.
    Returns (problem or None, details dict)."""
    salt = os.urandom(6).hex()
    d = "job-" + nonce
    ctxdir = os.path.join(WS, d)
    os.makedirs(ctxdir, exist_ok=True)
    shutil.copy(os.path.join(WORK, ".bench", "job"), os.path.join(ctxdir, "prog-" + nonce))
    open(os.path.join(ctxdir, "salt-" + nonce), "w").write(salt + "\n")
    open(os.path.join(ctxdir, "Dockerfile"), "w").write("FROM scratch\nCOPY prog-%s /app\nCOPY salt-%s /salt\nENTRYPOINT [\"/app\"]\n" % (nonce, nonce))
    img = "bench/job:" + tag
    info = {"salt": salt}
    r = cexec(cid, ["docker", "build", "-t", img, "%s/%s" % (WS_IN, d)])
    if r.returncode != 0:
        return "docker build in the agent container failed: " + short(r.stderr or r.stdout, 260), info
    r = cexec(cid, ["docker", "run", "--rm", "--network", "none", img, nonce])
    want = "job nonce=%s salt=%s" % (nonce, salt)
    if r.returncode != 0 or r.stdout.strip() != want:
        return "docker run printed %r (rc %d), wanted %r: %s" % (short(r.stdout, 80), r.returncode, want, short(r.stderr, 160)), info
    if hold:
        r = cexec(cid, ["docker", "run", "-d", "--network", "none", "--name", "hold-" + nonce, img, nonce, "hold"])
        if r.returncode != 0:
            return "docker run -d failed: " + short(r.stderr or r.stdout), info
        info["docker_id"] = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
        pid = wait_for(lambda: next((int(p) for p in os.listdir("/proc") if p.isdigit() and cmdargs(int(p))[-3:] == ["/app", nonce, "hold"]), 0), 15)
        info["pid"] = pid
    return None, info


def run_job_cleanup(cid, nonce, tag):
    cexec(cid, ["docker", "rm", "-f", "hold-" + nonce])
    cexec(cid, ["docker", "rmi", "-f", "bench/job:" + tag])
    shutil.rmtree(os.path.join(WS, "job-" + nonce), ignore_errors=True)


def chain(pid):
    out = []
    while pid > 1 and len(out) < 40:
        out.append((pid, comm(pid)))
        pid = ppid(pid)
    return out


NS_GET_PARENT = 0xb702


def pidns_ino(pid):
    try:
        return os.stat("/proc/%d/ns/pid" % pid).st_ino
    except OSError:
        return None


def pidns_parent_ino(pid):
    """inode of the parent PID namespace of the process's (the namespace of the process that created it), None when the kernel does not tell"""
    try:
        fd = os.open("/proc/%d/ns/pid" % pid, os.O_RDONLY)
    except OSError:
        return None
    try:
        pfd = fcntl.ioctl(fd, NS_GET_PARENT)
        ino = os.fstat(pfd).st_ino
        os.close(pfd)
        return ino
    except OSError:
        return None
    finally:
        os.close(fd)

t = load(WORK)


def fail(msg):
    print("[precondition] FAIL: " + msg)
    sys.exit(1)


p = lab_problem(t)
if p:
    fail(p)
if "--container-runtime=remote" not in cmdargs(pid_of(RUN + "/kubelet.pid")):
    fail("the kubelet does not use containerd's CRI")
sid, cs = wait_for(lambda: (lambda r: r if "agent" in r[1] else None)(pod_state()), 90) or (None, {})
if "agent" not in cs:
    fail("the pod jenkins has no running container agent")
if len(cs) != 1:
    fail("the pod jenkins is not as setup made it (containers: %s)" % ", ".join(sorted(cs)))
agent = cs["agent"]
mounts = {m["containerPath"]: m["hostPath"] for m in cri_json("inspect", agent).get("status", {}).get("mounts", [])}
if mounts.get("/var/run/docker.sock") != CSOCK or mounts.get(WS_IN) != WS:
    fail("the agent container does not mount containerd's socket as /var/run/docker.sock and the workspace (%s)" % short(str(mounts)))
r = cexec(agent, ["docker", "ps"])
if r.returncode == 0 or "malformed HTTP response" not in r.stderr:
    fail("control 1: docker ps in the agent container should fail with 'malformed HTTP response': " + short(r.stderr + r.stdout))
for d in os.listdir("/proc"):
    if d.isdigit() and comm(int(d)) == "dockerd":
        fail("a dockerd runs on this node (pid %s): the node has no Docker daemon" % d)

# control 2: the node can run a pod that has its own dockerd (a copy of the repaired pod under another name, removed again)
ctl = MANI + "/ctl.yaml"
IMG = CASE + ".local/%s:1"
open(ctl, "w").write("""apiVersion: v1
kind: Pod
metadata:
  name: ctl
  namespace: ci
spec:
  hostNetwork: true
  containers:
  - name: agent
    image: %s
    imagePullPolicy: Never
    volumeMounts:
    - {name: docker-run, mountPath: /var/run}
    - {name: workspace, mountPath: %s}
  - name: dind
    image: %s
    imagePullPolicy: Never
    securityContext: {privileged: true}
    volumeMounts:
    - {name: docker-run, mountPath: /var/run}
    - {name: docker-lib, mountPath: /var/lib/docker}
  volumes:
  - {name: docker-run, emptyDir: {}}
  - {name: docker-lib, emptyDir: {}}
  - name: workspace
    hostPath: {path: %s, type: Directory}
""" % (IMG % "agent", WS_IN, IMG % "dind", WS))
nonce = os.urandom(5).hex()
try:
    csid, ccs = wait_for(lambda: (lambda r: r if "agent" in r[1] and "dind" in r[1] else None)(pod_state("ctl-" + NODE)), 120) or (None, {})
    if "agent" not in ccs or "dind" not in ccs:
        fail("control 2: the control pod (agent + a privileged dind container) did not start on this node")
    if not wait_for(lambda: cexec(ccs["agent"], ["docker", "version", "--format", "{{.Server.Version}}"]).returncode == 0, 90):
        dl = crictl("logs", "--tail", "4", ccs["dind"])
        fail("control 2: the dockerd of the control pod did not come up: " + short(dl.stdout + dl.stderr, 300))
    prob, info = run_job(ccs["agent"], nonce, nonce)
    if prob:
        fail("control 2: " + prob)
finally:
    try:
        os.remove(ctl)
    except OSError:
        pass
    shutil.rmtree(os.path.join(WS, "job-" + nonce), ignore_errors=True)
    wait_for(lambda: pod_state("ctl-" + NODE)[0] is None, 90)
print("[precondition] OK: the agent's docker fails with 'malformed HTTP response' on containerd's socket; the node has no dockerd; a pod with its own dockerd builds and runs a job here")
PYEOF
) || { echo "$OUT"; exit 1; }
echo "$OUT"
