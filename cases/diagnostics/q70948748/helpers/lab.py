"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the real CRI pods of the case and the processes in them.

up:    imports two images into the 'k8s.io' namespace of the node's containerd (the sandbox image and the image of the workload, an application that
       starts processes when its script says so) and runs, through the CRI, with a network namespace each and the pod's name as host name:
         team-a/api-0 (containers app and sidecar) and team-b/api-0 (containers app and sidecar): two pods of the SAME name in two Kubernetes
         namespaces, each pod with its own random UID, every container with a tree of processes: its first process, a child, a grandchild (below the
         child) and an orphan (its parent exited; the first process of the container took it over).
       (A pod's processes are in a PID namespace per container, as with the kubelet; the first process of a container takes over its orphans.)
       A decoy on the host: a process of the node (it is not in any container) that has HOSTNAME=api-0 in its environment.
       The PIDs are whatever the kernel gave; the lab starts throw-away processes between the steps so they are not in step. WORK/target.pid holds
       the PID of the grandchild of the sidecar of team-b/api-0.
       The record, WORK/.bench/truth.json, comes from what this program created and from the process table of the host (the descendants of the first
       process of each container, told apart by the names the application gave them): every pod (UID, namespace, name), every container (id, name,
       first process, the other processes, with their start times), the decoy.
more:  the node changes: the pod team-c/api-0 (container app, with its tree) and a new container cache in team-a/api-0 (with its tree); new PIDs.
check: fails (one short line) unless the node is as recorded: the pods ready, the containers running with the same first process, every recorded
       process alive with the same start time and not stopped, the decoy alive, no container added."""
import json
import os
import random
import re
import secrets
import subprocess
import sys
import time
import uuid

CASE = "bench70948748"
PAUSE_REF = CASE + ".local/pause:1"
APP_REF = CASE + ".local/app:1"
NETNS_DIR = "/var/run/netns"
R = random.SystemRandom()


def cri(sock, *args, check=True):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "--timeout", "90s", *args],
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.stderr.write("crictl %s failed: %s\n" % (" ".join(args), r.stderr.strip()[-400:]))
        sys.exit(1)
    return r.stdout


def path(work, name):
    return os.path.join(work, ".bench", name)


def load(work):
    return json.load(open(path(work, "truth.json")))


def save(work, truth):
    json.dump(truth, open(path(work, "truth.json"), "w"), indent=1)


def remember(work, fname, line):
    open(path(work, fname), "a").write(line + "\n")


def procs():
    """pid -> (ppid, comm, start time, state) for every process of the host"""
    table = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                raw = open("/proc/%s/stat" % d).read()
            except OSError:
                continue
            head, tail = raw[:raw.index("(")], raw[raw.rindex(")") + 2:].split()
            table[int(d)] = (int(tail[1]), raw[raw.index("(") + 1:raw.rindex(")")], int(tail[19]), tail[0])
    return table


def descendants(table, root):
    out, todo = [], [root]
    while todo:
        p = todo.pop()
        for q, (pp, _, _, _) in table.items():
            if pp == p:
                out.append(q)
                todo.append(q)
    return out


def churn():
    """throw-away processes, so that the PIDs of what is started next are not in step"""
    for _ in range(R.randint(0, 40)):
        subprocess.run(["true"])


def import_image(sock, work, ref, binary, name):
    tar = path(work, "image.tar")
    subprocess.run([sys.executable, path(work, "mkimg.py"), ref, path(work, binary), name, tar], check=True, capture_output=True)
    os.chmod(tar, 0o644)
    r = subprocess.run(["sudo", "ctr", "-a", sock, "-n", "k8s.io", "images", "import", tar], capture_output=True, text=True)
    os.unlink(tar)
    if r.returncode != 0:
        sys.stderr.write("ctr could not import %s: %s\n" % (ref, r.stderr.strip()[-300:]))
        sys.exit(1)
    for _ in range(40):
        if subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + sock, "--image-endpoint", "unix://" + sock, "inspecti", ref],
                          capture_output=True).returncode == 0:
            return
        time.sleep(0.5)
    sys.stderr.write("the CRI does not know the image %s\n" % ref)
    sys.exit(1)


def run_pod(sock, work, truth, ns, pod):
    puid = str(uuid.uuid4())
    labels = {"io.kubernetes.pod.name": pod, "io.kubernetes.pod.namespace": ns, "io.kubernetes.pod.uid": puid}
    pod_file = path(work, "pod-%s-%s.json" % (ns, pod))
    json.dump({"metadata": {"name": pod, "namespace": ns, "uid": puid, "attempt": 0}, "hostname": pod, "labels": labels,
               "linux": {"security_context": {"namespace_options": {"pid": 1}}}}, open(pod_file, "w"))   # pid: CONTAINER, as the kubelet sets it
    before = set(os.listdir(NETNS_DIR)) if os.path.isdir(NETNS_DIR) else set()
    sid = cri(sock, "runp", pod_file).strip()
    remember(work, "ids.txt", sid)
    for n in sorted(set(os.listdir(NETNS_DIR)) - before) if os.path.isdir(NETNS_DIR) else []:
        remember(work, "netns.txt", os.path.join(NETNS_DIR, n))
    truth["pods"][sid] = {"ns": ns, "name": pod, "uid": puid, "file": pod_file}
    save(work, truth)
    churn()
    return sid


def add_container(sock, work, truth, sid, name, gen):
    p = truth["pods"][sid]
    labels = {"io.kubernetes.pod.name": p["name"], "io.kubernetes.pod.namespace": p["ns"], "io.kubernetes.pod.uid": p["uid"],
              "io.kubernetes.container.name": name}
    data = os.path.join(work, "data", "%s-%s-%s" % (p["ns"], p["name"], name))
    os.makedirs(data, exist_ok=True)
    open(os.path.join(data, "script.txt"), "w").write("t\nr\n")
    cfg = {"metadata": {"name": name, "attempt": 0}, "image": {"image": APP_REF}, "args": ["serve", "/data/script.txt"], "labels": labels,
           "mounts": [{"container_path": "/data", "host_path": data, "readonly": True}],
           "linux": {"security_context": {"namespace_options": {"pid": 1}}}}   # pid: CONTAINER, as the kubelet sets it (in the pod and in the container)
    cfile = path(work, "ctr-%s-%s-%s.json" % (p["ns"], p["name"], name))
    json.dump(cfg, open(cfile, "w"))
    cid = cri(sock, "create", sid, cfile, p["file"]).strip()
    remember(work, "ids.txt", cid)
    cri(sock, "start", cid)
    init = 0
    for _ in range(40):
        init = int(json.loads(cri(sock, "inspect", "-o", "json", cid))["info"].get("pid", 0))
        if init > 0:
            break
        time.sleep(0.25)
    found = {}
    for _ in range(60):
        table = procs()
        found = {table[q][1]: q for q in descendants(table, init) if table[q][1] in ("child", "grandchild", "orphan")}
        if len(found) == 3:
            break
        time.sleep(0.25)
    else:
        sys.stderr.write("the container %s of %s/%s did not start its processes (%s)\n" % (name, p["ns"], p["name"], sorted(found)))
        sys.exit(1)
    table = procs()
    mine = {"init": init, **found}
    truth["containers"][cid] = {"sandbox": sid, "name": name, "gen": gen, "procs": mine, "start": {str(q): table[q][2] for q in mine.values()}}
    save(work, truth)
    print("%s/%s %s: container %s, first process %d, child %d, grandchild %d, orphan %d" % (
        p["ns"], p["name"], name, cid[:12], init, found["child"], found["grandchild"], found["orphan"]))
    churn()


def decoy(work, truth):
    pidfile = path(work, "host.pid")
    cmd = 'echo $$ > "$1"; HOSTNAME=api-0 exec -a "$2" sleep 36000'
    subprocess.run(["sudo", "setsid", "-f", "bash", "-c", cmd, "_", pidfile, os.path.join(work, "host-process")], check=True,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(40):
        try:
            pid = int(open(pidfile).read().strip())
            if procs().get(pid, (0, "", 0, ""))[1] == "sleep":
                truth["host"] = {"pid": pid, "start": procs()[pid][2]}
                save(work, truth)
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.25)
    sys.stderr.write("the decoy process did not start\n")
    sys.exit(1)


def up(sock, work):
    truth = {"pods": {}, "containers": {}, "host": None}
    save(work, truth)
    import_image(sock, work, PAUSE_REF, "idle-bin", "pause")
    import_image(sock, work, APP_REF, "app-bin", "app")
    order = [("team-a", "api-0"), ("team-b", "api-0")]
    R.shuffle(order)
    for ns, pod in order:
        sid = run_pod(sock, work, truth, ns, pod)
        for name in R.sample(["app", "sidecar"], 2):
            add_container(sock, work, truth, sid, name, 1)
    decoy(work, truth)
    sc = [c for c in truth["containers"].values() if c["name"] == "sidecar" and truth["pods"][c["sandbox"]]["ns"] == "team-b"][0]
    open(os.path.join(work, "target.pid"), "w").write("%d\n" % sc["procs"]["grandchild"])


def more(sock, work):
    truth = load(work)
    sid = run_pod(sock, work, truth, "team-c", "api-0")
    add_container(sock, work, truth, sid, "app", 2)
    a = [s for s, p in truth["pods"].items() if p["ns"] == "team-a"][0]
    add_container(sock, work, truth, a, "cache", 2)
    print("added the pod team-c/api-0 and the container cache to team-a/api-0")


def check(sock, work):
    truth = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    pods = {p["id"]: p["state"] for p in json.loads(cri(sock, "pods", "-o", "json"))["items"]}
    for sid, p in truth["pods"].items():
        if pods.get(sid) != "SANDBOX_READY":
            bad("the pod %s/%s is gone or not ready" % (p["ns"], p["name"]))
    if [s for s in pods if s not in truth["pods"]]:
        bad("pod(s) were added")
    live = {c["id"]: c["state"] for c in json.loads(cri(sock, "ps", "-a", "-o", "json"))["containers"]}
    table = procs()
    for cid, c in truth["containers"].items():
        who = "%s of %s/%s" % (c["name"], truth["pods"][c["sandbox"]]["ns"], truth["pods"][c["sandbox"]]["name"])
        if live.get(cid) != "CONTAINER_RUNNING":
            bad("the container %s is gone or not running" % who)
        for label, pid in c["procs"].items():
            t = table.get(pid)
            if t is None or t[2] != c["start"][str(pid)] or t[3] == "T":
                bad("the process %d (%s of the container %s) is gone, replaced or stopped" % (pid, label, who))
    if [i for i in live if i not in truth["containers"]]:
        bad("container(s) were added")
    h = truth["host"]
    t = table.get(h["pid"]) if h else None
    if h and (t is None or t[2] != h["start"] or t[3] == "T"):
        bad("the process %d of the node is gone, replaced or stopped" % h["pid"])


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
