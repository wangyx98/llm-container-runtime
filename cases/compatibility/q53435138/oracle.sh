#!/bin/bash
set -e

CASE_ID="bench53435138"
WORK_DIR="/tmp/$CASE_ID"

echo "[oracle] the pod jenkins as the node's kubelet runs it: only the node's images, no host socket or host root, no host PID/IPC; plain docker in the agent container builds (cold, FROM scratch) and runs two jobs; the daemon is the command of a container of the pod and the job's container is in a PID namespace below it, never the node's containerd..."
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
KPODS = KROOT + "/pods/"


def fail(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


p = lab_problem(t)
if p:
    fail(p)

# the pod as it runs now (the solution changes the manifest, the kubelet makes a new pod)
def ready():
    sid, cs = pod_state()
    return (sid, cs) if "agent" in cs else None


sid, cs = wait_for(ready, 120) or (None, {})
if "agent" not in cs:
    fail("the pod %s has no running container agent (containers: %s); the kubelet's last error: %s" % (POD, ", ".join(sorted(cs)) or "none",
         short(" ".join([ln for ln in (read(RUN + "/kubelet.log") or "").splitlines() if re.match(r"^[EF]\d{4} ", ln)][-1:]), 200)))
no = cri_json("inspectp", sid).get("info", {}).get("config", {}).get("linux", {}).get("security_context", {}).get("namespace_options", {})
if no.get("pid") == 2 or no.get("ipc") == 2:
    fail("the pod uses the host's PID or IPC namespace")
imgs = set(t["images"].values())
inits = []
cmds = {}      # init pid of a container -> its command line as the pod's spec gives it
for name, cid in cs.items():
    ins = cri_json("inspect", cid)
    if ins.get("status", {}).get("imageRef") not in imgs:
        fail("the container %s runs an image that is not one of the node's (%s)" % (name, ins.get("status", {}).get("imageRef")))
    for m in ins.get("status", {}).get("mounts", []):
        hp = m.get("hostPath", "")
        if not (hp == WS or hp.startswith(KPODS)):
            fail("the container %s mounts the host path %s on %s: no host socket, root or other host directory may be shared with the pod (only the workspace)" % (name, hp, m.get("containerPath")))
        if hp == WS and name == "agent" and m.get("containerPath") != WS_IN:
            fail("the workspace is not mounted at %s in the agent container" % WS_IN)
    inits.append(ins.get("info", {}).get("pid", 0))
    cmds[inits[-1]] = " ".join(ins.get("info", {}).get("runtimeSpec", {}).get("process", {}).get("args", []))
agent = cs["agent"]
if WS not in [m.get("hostPath") for m in cri_json("inspect", agent).get("status", {}).get("mounts", [])]:
    fail("the agent container has no workspace mount")

# plain `docker` (no options) in the agent container: first the daemon has to answer
if not wait_for(lambda: cexec(agent, ["docker", "version", "--format", "{{.Server.Version}}"]).returncode == 0, 120):
    r = cexec(agent, ["docker", "version"])
    fail("docker in the agent container does not reach a daemon: " + short(r.stderr, 260))

done = []
for i in (1, 2):
    nonce = os.urandom(5).hex()
    prob, info = run_job(agent, nonce, nonce, hold=True)
    try:
        if prob:
            fail("job %d: %s" % (i, prob))
        pid = info.get("pid")
        if not pid:
            fail("job %d: the container of `docker run -d` has no process on the node" % i)
        # the job's container lives in a PID namespace made by a process of the pod (the namespace of the dockerd that started it), and that dockerd is the command of
        # a container of the pod (the init of a container, or a descendant of it): not a dockerd of the node, not one `exec`ed into a pod that does not carry it
        parent = pidns_parent_ino(pid)
        dockerds = [int(d) for d in os.listdir("/proc") if d.isdigit() and comm(int(d)) == "dockerd"]
        if parent is None:
            fail("job %d: the kernel does not tell the parent PID namespace of the job's container" % i)
        own = [d for d in dockerds if pidns_ino(d) == parent]
        if not own:
            fail("job %d: the job's container is not in a PID namespace below a dockerd (its ancestors: %s; dockerd processes on the node: %s)" % (i, " > ".join(c for _, c in chain(pid)), dockerds or "none"))
        if not any("dockerd" in cmds.get(x, "") for d in own for x in [q for q, _ in chain(d)] if x in cmds):
            fail("job %d: the dockerd of the job (pid %d) is not run by the command of a container of the pod %s: no container of the pod has a command that starts dockerd (commands: %s)"
                 % (i, own[0], POD, short(str(sorted(cmds.values())), 160)))
        # the node's containerd knows nothing of the job: its containers are the pod's, its images the node's
        if info["docker_id"] and info["docker_id"] in ctr("k8s.io", "containers", "ls", "-q").stdout.split():
            fail("job %d: the job's container is a container of the node's containerd" % i)
        if "bench/job:" + nonce in ctr("k8s.io", "images", "ls", "-q").stdout:
            fail("job %d: the job's image is an image of the node's containerd" % i)
        done.append(nonce)
    finally:
        run_job_cleanup(agent, nonce, nonce)
print("[oracle] PASS: docker in the agent container built and ran two jobs on a dockerd that a container of the pod %s runs as its command (the job's container is in a PID namespace made below that dockerd); the node's containerd has neither the jobs' containers nor their images; no host socket, host root or host PID/IPC" % POD)
PYEOF
) || { echo "$OUT"; exit 1; }
echo "$OUT"
