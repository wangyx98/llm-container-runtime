"""lab.py up|more|check DSOCK CSOCK WORK : the workloads of the node, in ONE containerd that Docker and the CRI plugin share.

The node has one containerd (socket CSOCK) with the CRI plugin, and a Docker daemon (socket DSOCK) that uses that same containerd. Each API keeps its objects in a
containerd namespace of its own: Docker in `moby`, the CRI plugin in `k8s.io`; the namespace `default` (where `ctr` looks without -n) is empty. A Kubernetes namespace
(the namespace of a pod, here `default` too) is another thing than a containerd namespace.
up:    Docker runs web and db (the program of the image waits for ever) and has job, which ran and exited. The CRI has one pod sandbox web-0 (Kubernetes namespace
       default, network of the node) with the containers app and sidecar (running) and job (exited). The sandbox is also a container of containerd, in k8s.io.
more:  the node changes: Docker gets a new running container cache and loses job; the pod gets a new running container worker and loses job.
The record, WORK/.bench/truth.json: {"docker": {ID: {name, pid}}, "cri": {ID: {name, pid}}, "sandboxes": {ID: {name, pid}}, "pod": {...}}. The IDs are what `docker run`,
`crictl runp` and `crictl create` printed; the PID of a running one is what the runtime that started it reported (docker inspect, crictl inspect) once, with its start time from /proc, so a restart
or a new process under the same PID is seen (pid null: it has exited). What each API must list follows from it: `docker ps -a`: the docker IDs; containerd's moby: the running ones among them (Docker removes a container from containerd when it stops); `crictl ps -a`: the cri IDs; `crictl pods`: the
sandboxes; containerd's k8s.io: the sandboxes and the cri IDs together.
check: fails (one short line) unless the node is as the record says: exactly these containers in Docker, in the CRI and in the containers of both containerd namespaces
       (default empty), every running one with the PID it had and every exited one still exited (nothing created, started, stopped, removed, pruned or moved since)."""
import json
import os
import subprocess
import sys
import time
import uuid

POD, K8S_NS = "web-0", "default"
NETNS = {"linux": {"security_context": {"namespace_options": {"network": 2, "pid": 1}}}}   # network: NODE (no CNI needed); pid: CONTAINER
DOCKER_NAMES = {"web": "bench48616250-web", "db": "bench48616250-db", "job": "bench48616250-job", "cache": "bench48616250-cache"}
APP_REF = "bench/app:1"             # the ref Docker has; containerd names it docker.io/bench/app:1


def run(cmd, check=True, timeout=120):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        sys.stderr.write("%s failed: %s\n" % (" ".join(cmd[:6]), r.stderr.strip()[-300:]))
        sys.exit(1)
    return r.stdout.strip()


def docker(dsock, *args, check=True):
    return run(["docker", "-H", "unix://" + dsock, *args], check)


def ctr(csock, *args, check=True):
    return run(["sudo", "ctr", "-a", csock, *args], check)


def cri(csock, *args, check=True):
    return run(["sudo", "crictl", "--runtime-endpoint", "unix://" + csock, "--image-endpoint", "unix://" + csock, "--timeout", "90s", *args], check)


def bench(work, *parts):
    return os.path.join(work, ".bench", *parts)


def load(work):
    return json.load(open(bench(work, "truth.json")))


def save(work, t):
    json.dump(t, open(bench(work, "truth.json"), "w"), indent=1)


def remember(work, cid):
    open(bench(work, "ids.txt"), "a").write(cid + "\n")          # cleanup.sh removes the runc state of these IDs


def started(pid):
    """the start time (clock ticks since boot) and state of a process of the host, from /proc; None when it does not exist"""
    try:
        stat = open("/proc/%d/stat" % pid).read()
    except OSError:
        return None
    f = stat[stat.rindex(")") + 2:].split()
    return int(f[19]), f[0]


def inspect_cri(csock, cid, sandbox=False):
    d = json.loads(cri(csock, "inspectp" if sandbox else "inspect", "-o", "json", cid))
    return d["status"]["state"], int(d.get("info", {}).get("pid", 0) or 0)


def wait_running(get):
    """get() -> (state, pid); wait for a running process and return its record {pid, start}"""
    for _ in range(80):
        state, pid = get()
        if state in ("running", "CONTAINER_RUNNING", "SANDBOX_READY") and pid > 0 and started(pid):
            return {"pid": pid, "start": started(pid)[0]}
        time.sleep(0.25)
    sys.stderr.write("no running process (last state %s)\n" % state)
    sys.exit(1)


def wait_exited(get):
    for _ in range(80):
        if get()[0] in ("exited", "CONTAINER_EXITED"):
            return {"pid": None, "start": None}
        time.sleep(0.25)
    sys.stderr.write("the container did not exit\n")
    sys.exit(1)


def docker_state(dsock, cid):
    state, pid = docker(dsock, "inspect", "-f", "{{.State.Status}} {{.State.Pid}}", cid).split()
    return state, int(pid)


def docker_run(dsock, work, t, key, *cmd):
    cid = docker(dsock, "run", "-d", "--name", DOCKER_NAMES[key], APP_REF, *cmd)
    remember(work, cid)
    get = lambda: docker_state(dsock, cid)
    t["docker"][cid] = {"name": DOCKER_NAMES[key], **(wait_exited(get) if cmd and cmd[0] == "attr" else wait_running(get))}


def cri_run(csock, work, t, name, arg):
    cfg = bench(work, name + ".json")
    json.dump({"metadata": {"name": name, "attempt": 0}, "image": {"image": "docker.io/" + APP_REF}, "args": [arg], **NETNS}, open(cfg, "w"))
    cid = cri(csock, "create", t["pod"]["id"], cfg, bench(work, "pod.json"))
    remember(work, cid)
    cri(csock, "start", cid)
    get = lambda: inspect_cri(csock, cid)
    t["cri"][cid] = {"name": name, **(wait_exited(get) if arg == "attr" else wait_running(get))}


def describe(t):
    return "docker: %d containers; cri: %d containers in %d pod; containerd: moby %d, k8s.io %d" % (
        len(t["docker"]), len(t["cri"]), len(t["sandboxes"]), sum(1 for v in t["docker"].values() if v["pid"]), len(t["cri"]) + len(t["sandboxes"]))


def up(dsock, csock, work):
    t = {"docker": {}, "cri": {}, "sandboxes": {}, "pod": {"name": POD, "namespace": K8S_NS, "uid": str(uuid.uuid4())}}
    docker(dsock, "load", "-i", bench(work, "app.tar"))
    pod = {"metadata": {"name": POD, "namespace": K8S_NS, "uid": t["pod"]["uid"], "attempt": 0}, **NETNS}
    json.dump(pod, open(bench(work, "pod.json"), "w"))
    sid = cri(csock, "runp", bench(work, "pod.json"))
    remember(work, sid)
    t["pod"]["id"] = sid
    t["sandboxes"][sid] = {"name": POD, **wait_running(lambda: inspect_cri(csock, sid, True))}
    docker_run(dsock, work, t, "web")
    docker_run(dsock, work, t, "db")
    docker_run(dsock, work, t, "job", "attr")
    cri_run(csock, work, t, "app", "serve")
    cri_run(csock, work, t, "sidecar", "serve")
    cri_run(csock, work, t, "job", "attr")
    save(work, t)
    print(describe(t))


def more(dsock, csock, work):
    t = load(work)
    docker_run(dsock, work, t, "cache")
    djob = next(k for k, v in t["docker"].items() if v["name"] == DOCKER_NAMES["job"])
    docker(dsock, "rm", djob)
    del t["docker"][djob]
    cri_run(csock, work, t, "worker", "serve")
    cjob = next(k for k, v in t["cri"].items() if v["name"] == "job")
    cri(csock, "rm", cjob)
    del t["cri"][cjob]
    save(work, t)
    print(describe(t))


def check(dsock, csock, work):
    t = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    spaces = sorted(ctr(csock, "namespaces", "ls", "-q").split())
    if spaces != ["k8s.io", "moby"]:
        bad("the containerd namespaces are %s, not k8s.io moby" % " ".join(spaces))
    dock = sorted(docker(dsock, "ps", "-aq", "--no-trunc").split())
    if dock != sorted(t["docker"]):
        bad("Docker has %d containers, the lab left %d" % (len(dock), len(t["docker"])))
    if sorted(ctr(csock, "-n", "moby", "containers", "ls", "-q").split()) != sorted(k for k, v in t["docker"].items() if v["pid"]):
        bad("containerd has another set of containers in the namespace moby")
    if sorted(cri(csock, "ps", "-a", "-q", "--no-trunc").split()) != sorted(t["cri"]):
        bad("the CRI has another set of containers")
    if sorted(cri(csock, "pods", "-q", "--no-trunc").split()) != sorted(t["sandboxes"]):
        bad("the CRI has another set of pods")
    if sorted(ctr(csock, "-n", "k8s.io", "containers", "ls", "-q").split()) != sorted(list(t["cri"]) + list(t["sandboxes"])):
        bad("containerd has another set of containers in the namespace k8s.io")
    if ctr(csock, "-n", "default", "containers", "ls", "-q").split():
        bad("the namespace default of containerd has containers")
    for group in (t["docker"], t["cri"], t["sandboxes"]):
        for cid, v in group.items():
            if v["pid"] is None:
                continue
            p = started(v["pid"])
            if p is None or p[0] != v["start"] or p[1] in ("Z", "T"):
                bad("the process of %s (pid %d) is gone, replaced or stopped" % (v["name"], v["pid"]))
    for cid, v in t["docker"].items():
        if v["pid"] is None and docker_state(dsock, cid)[0] != "exited":
            bad("the container %s of Docker is not exited any more" % v["name"])
    for cid, v in t["cri"].items():
        if v["pid"] is None and inspect_cri(csock, cid)[0] != "CONTAINER_EXITED":
            bad("the container %s of the CRI is not exited any more" % v["name"])


if __name__ == "__main__":
    cmd, dsock, csock, work = sys.argv[1:5]
    {"up": up, "more": more, "check": check}[cmd](dsock, csock, work)
