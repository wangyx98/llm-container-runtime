"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the real CRI pods of the case, and what the node must report about them.

up:    imports two images into the 'k8s.io' namespace of the node's containerd (the sandbox image, whose only program is /pause, and the workload
       image, whose only program is /work) and runs, through the CRI, two pods, each with a network namespace of its own: shop/web-0 (containers
       app and sidecar, both /work) and shop/db-0 (containers db, /work, and holder, which runs the sandbox image: a process called pause that is
       NOT a pod sandbox). What the node holds is recorded in WORK/.bench/truth.json, from what this program created and from /proc, not from what
       a tool of the solution answers: every sandbox (its pod, the pid of its pause process, its net namespace) and every container (its sandbox,
       name, pid, net namespace).
more:  the node changes: runs the pod infra/cache-0 (container redis) and adds a container log to shop/web-0. The record is updated.
check: fails (one short line) unless the node still holds exactly what the record says: the same sandboxes ready with the same pause pids, the
       same containers running with the same pids (nothing deleted, recreated or restarted, nothing added), the same net namespaces."""
import json
import os
import subprocess
import sys
import time
import uuid

CASE = "bench71482106"
PAUSE_REF = CASE + ".local/pause:1"
WORK_REF = CASE + ".local/work:1"
NETNS_DIR = "/var/run/netns"   # where containerd keeps the net namespace of a pod (bind mounts, which a killed containerd does not remove)


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


def netns_of(pid):
    r = subprocess.run(["sudo", "readlink", "/proc/%d/ns/net" % pid], capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.startswith("net:["):
        sys.stderr.write("no net namespace for pid %d\n" % pid)
        sys.exit(1)
    return int(r.stdout.strip()[5:-1])


def pid_of(sock, kind, i):
    """the pid of a sandbox (kind inspectp) or of a container (kind inspect), 0 when it has none"""
    return int(json.loads(cri(sock, kind, "-o", "json", i))["info"].get("pid", 0))


def import_image(sock, work, ref, name):
    tar = path(work, "image.tar")
    subprocess.run([sys.executable, path(work, "mkimg.py"), ref, path(work, "idle-bin"), name, tar], check=True, capture_output=True)
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
    """runs the sandbox of a pod (with the labels the kubelet puts on it) and returns its id"""
    puid = str(uuid.uuid4())
    labels = {"io.kubernetes.pod.name": pod, "io.kubernetes.pod.namespace": ns, "io.kubernetes.pod.uid": puid}
    pod_file = path(work, "pod-%s-%s.json" % (ns, pod))
    json.dump({"metadata": {"name": pod, "namespace": ns, "uid": puid, "attempt": 0}, "labels": labels}, open(pod_file, "w"))
    before = set(os.listdir(NETNS_DIR)) if os.path.isdir(NETNS_DIR) else set()
    sid = cri(sock, "runp", pod_file).strip()
    remember(work, "ids.txt", sid)
    for n in sorted(set(os.listdir(NETNS_DIR)) - before) if os.path.isdir(NETNS_DIR) else []:
        remember(work, "netns.txt", os.path.join(NETNS_DIR, n))
    pid = pid_of(sock, "inspectp", sid)
    if pid <= 0:
        sys.stderr.write("the sandbox of %s/%s has no pause process\n" % (ns, pod))
        sys.exit(1)
    truth["sandboxes"][sid] = {"pod": "%s/%s" % (ns, pod), "uid": puid, "file": pod_file, "pid": pid, "netns": netns_of(pid)}
    save(work, truth)
    print("%s/%s: sandbox %s, pause pid %d" % (ns, pod, sid[:12], pid))
    return sid


def add_container(sock, work, truth, sid, name, ref):
    s = truth["sandboxes"][sid]
    ns, pod = s["pod"].split("/")
    labels = {"io.kubernetes.pod.name": pod, "io.kubernetes.pod.namespace": ns, "io.kubernetes.pod.uid": s["uid"], "io.kubernetes.container.name": name}
    cfile = path(work, "ctr-%s-%s.json" % (pod, name))
    json.dump({"metadata": {"name": name, "attempt": 0}, "image": {"image": ref}, "labels": labels}, open(cfile, "w"))
    cid = cri(sock, "create", sid, cfile, s["file"]).strip()
    remember(work, "ids.txt", cid)
    cri(sock, "start", cid)
    pid = 0
    for _ in range(40):
        pid = pid_of(sock, "inspect", cid)
        if pid > 0:
            break
        time.sleep(0.25)
    else:
        sys.stderr.write("the container %s did not start\n" % name)
        sys.exit(1)
    truth["containers"][cid] = {"sandbox": sid, "name": name, "pid": pid, "netns": netns_of(pid)}
    save(work, truth)
    print("  container %s: %s, pid %d" % (name, cid[:12], pid))


def up(sock, work):
    truth = {"sandboxes": {}, "containers": {}}
    save(work, truth)
    import_image(sock, work, PAUSE_REF, "pause")
    import_image(sock, work, WORK_REF, "work")
    sid = run_pod(sock, work, truth, "shop", "web-0")
    add_container(sock, work, truth, sid, "app", WORK_REF)
    add_container(sock, work, truth, sid, "sidecar", WORK_REF)
    sid = run_pod(sock, work, truth, "shop", "db-0")
    add_container(sock, work, truth, sid, "db", WORK_REF)
    add_container(sock, work, truth, sid, "holder", PAUSE_REF)


def more(sock, work):
    truth = load(work)
    sid = run_pod(sock, work, truth, "infra", "cache-0")
    add_container(sock, work, truth, sid, "redis", WORK_REF)
    web = [s for s, v in truth["sandboxes"].items() if v["pod"] == "shop/web-0"][0]
    add_container(sock, work, truth, web, "log", WORK_REF)
    print("added the pod infra/cache-0 and the container log to shop/web-0")


def check(sock, work):
    truth = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    pods = {p["id"]: p["state"] for p in json.loads(cri(sock, "pods", "-o", "json"))["items"]}
    for sid, s in truth["sandboxes"].items():
        if pods.get(sid) != "SANDBOX_READY":
            bad("the pod %s (sandbox %s) is gone or not ready" % (s["pod"], sid[:12]))
        if pid_of(sock, "inspectp", sid) != s["pid"]:
            bad("the pause process of %s is not the one of the lab any more (recreated)" % s["pod"])
    extra = [i for i in pods if i not in truth["sandboxes"]]
    if extra:
        bad("%d pod(s) were added (%s)" % (len(extra), ", ".join(i[:12] for i in extra[:3])))
    live = {c["id"]: c["state"] for c in json.loads(cri(sock, "ps", "-a", "-o", "json"))["containers"]}
    for cid, c in truth["containers"].items():
        who = "%s of %s" % (c["name"], truth["sandboxes"][c["sandbox"]]["pod"])
        if cid not in live:
            bad("the container %s (%s) is gone" % (cid[:12], who))
        if live[cid] != "CONTAINER_RUNNING" or pid_of(sock, "inspect", cid) != c["pid"]:
            bad("the container %s (%s) was restarted or stopped" % (cid[:12], who))
        if netns_of(c["pid"]) != c["netns"]:
            bad("the container %s (%s) changed its net namespace" % (cid[:12], who))
    extra = [i for i in live if i not in truth["containers"]]
    if extra:
        bad("%d container(s) were added (%s)" % (len(extra), ", ".join(i[:12] for i in extra[:3])))


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
