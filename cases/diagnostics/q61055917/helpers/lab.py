"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the workload of the node's containerd (the MicroK8s one) and what the node must report.

The node's containerd keeps everything in the namespace k8s.io, as the containerd of MicroK8s does; the namespace default is empty. The containers are
made with `ctr` (no CRI pods) with the 64-hex-digit IDs a kubelet gives, the program in every image does nothing and never exits.
up:    five images are imported into k8s.io: k8s.gcr.io/pause:3.1, registry.local/kube/pause:3.1 (another image with the same name and tag, other
       registry), docker.io/jupyterhub/configurable-http-proxy:4.1.0, docker.io/metacontroller/jsonnetd:0.1 and docker.io/library/busybox:1.31 (no container
       uses it). Six containers: two of k8s.gcr.io/pause, one of registry.local/kube/pause, the proxy and one jsonnetd run; a second jsonnetd container
       was created and never started (no task, no PID).
more:  the node changes: the task of the proxy is killed and removed (no task), the container that was never started gets a task, and a new image
       docker.io/seldonio/seldon-core-operator:1.0.1 is imported with a new container that runs.
The record, WORK/.bench/truth.json: {"containers": {ID: {image, digest, pid}}, "images": {REF: DIGEST}, "content": [blobs], "records": {ID: sha of the container's
record}, "namespaces": [...]}. The CRI plugin adds entries named by a bare image ID (sha256:...) in k8s.io; they are not recorded and not compared. The digests come from what mkimg.py built, and the PID of a task from the process table of the host (the child of the container's
shim), never from what `ctr` reports. pid is null for a container that has no task.
check: fails (one short line) unless the node is as the record says: the same namespaces, the same images with the same digests and blobs, the same containers
       with unchanged records, and exactly the recorded tasks with the recorded PIDs (nothing pulled, imported, tagged, removed, started, stopped or killed since)."""
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time

NS = "k8s.io"
PAUSE, PAUSE2 = "k8s.gcr.io/pause:3.1", "registry.local/kube/pause:3.1"
PROXY, JSONNET = "docker.io/jupyterhub/configurable-http-proxy:4.1.0", "docker.io/metacontroller/jsonnetd:0.1"
UNUSED, NEW = "docker.io/library/busybox:1.31", "docker.io/seldonio/seldon-core-operator:1.0.1"
UP = [(PAUSE, True), (PAUSE, True), (PAUSE2, True), (PROXY, True), (JSONNET, True), (JSONNET, False)]


def ctr(sock, *args, check=True, timeout=60):
    r = subprocess.run(["sudo", "ctr", "-a", sock, *args], capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        sys.stderr.write("ctr %s failed: %s\n" % (" ".join(args[:6]), r.stderr.strip()[-300:]))
        sys.exit(1)
    return r.stdout


def path(work, name):
    return os.path.join(work, ".bench", name)


def load(work):
    return json.load(open(path(work, "truth.json")))


def save(work, t):
    json.dump(t, open(path(work, "truth.json"), "w"), indent=1)


def live_images(sock):
    out = {}
    for line in ctr(sock, "-n", NS, "images", "ls").splitlines()[1:]:
        f = line.split()
        if f and not f[0].startswith("sha256:"):      # the CRI plugin of k8s.io adds an entry named by the image ID for every import
            out[f[0]] = f[2]
    return out


def live_content(sock):
    return sorted(ctr(sock, "-n", NS, "content", "ls", "-q").split())


def record_hash(sock, cid):
    return hashlib.sha256(ctr(sock, "-n", NS, "containers", "info", cid).encode()).hexdigest()


def import_image(sock, work, t, ref):
    tar = path(work, "image.tar")
    r = subprocess.run([sys.executable, path(work, "mkimg.py"), ref, secrets.token_hex(6), path(work, "idle-bin"), "idle", tar],
                       capture_output=True, text=True, check=True)
    os.chmod(tar, 0o644)
    ctr(sock, "-n", NS, "images", "import", tar)
    os.unlink(tar)
    t["images"][ref] = json.loads(r.stdout)["manifest"]


def shim_child(cid):
    """the PID of the first process of the container, from the process table: the child of the shim started for (NS, cid)"""
    shim = None
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            argv = open("/proc/%s/cmdline" % d, "rb").read().split(b"\0")
        except OSError:
            continue
        if b"-namespace" in argv and b"-id" in argv:
            try:
                if argv[argv.index(b"-namespace") + 1].decode() == NS and argv[argv.index(b"-id") + 1].decode() == cid:
                    shim = int(d)
                    break
            except IndexError:
                continue
    if shim is None:
        return None
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                stat = open("/proc/%s/stat" % d).read()
            except OSError:
                continue
            if int(stat[stat.rindex(")") + 2:].split()[1]) == shim:
                return int(d)
    return None


def wait_pid(cid):
    for _ in range(60):
        p = shim_child(cid)
        if p:
            return p
        time.sleep(0.25)
    sys.stderr.write("no process of the container %s\n" % cid)
    sys.exit(1)


def task_table(sock):
    out = {}
    for line in ctr(sock, "-n", NS, "tasks", "ls").splitlines()[1:]:
        f = line.split()
        if len(f) >= 3:
            out[f[0]] = (int(f[1]), f[2].lower())
    return out


def make(sock, work, t, ref, task):
    cid = secrets.token_hex(32)
    open(path(work, "ids.txt"), "a").write(cid + "\n")          # cleanup.sh removes the runc state of these IDs
    if task:
        ctr(sock, "-n", NS, "run", "-d", ref, cid)
        pid = wait_pid(cid)
    else:
        ctr(sock, "-n", NS, "containers", "create", ref, cid)
        pid = None
    t["containers"][cid] = {"image": ref, "digest": t["images"][ref], "pid": pid}


def settle(sock, work, t):
    """wait until the content store stops changing (the import is garbage collected), then record everything the check compares"""
    prev = None
    for _ in range(40):
        cur = live_content(sock)
        if cur == prev:
            break
        prev = cur
        time.sleep(0.5)
    t["content"] = cur
    t["records"] = {cid: record_hash(sock, cid) for cid in t["containers"]}
    t["namespaces"] = sorted(ctr(sock, "namespaces", "ls", "-q").split())
    save(work, t)


def describe(t):
    c = t["containers"]
    return "%d images, %d containers (%d with a task)" % (len(t["images"]), len(c), sum(1 for v in c.values() if v["pid"]))


def up(sock, work):
    t = {"containers": {}, "images": {}}
    for ref in (PAUSE, PAUSE2, PROXY, JSONNET, UNUSED):
        import_image(sock, work, t, ref)
    for ref, task in UP:
        make(sock, work, t, ref, task)
    settle(sock, work, t)
    print(describe(t))


def more(sock, work):
    t = load(work)
    c = t["containers"]
    proxy = next(k for k, v in c.items() if v["image"] == PROXY)
    idle = next(k for k, v in c.items() if v["pid"] is None)
    ctr(sock, "-n", NS, "tasks", "kill", "-s", "SIGKILL", proxy)
    for _ in range(60):
        if task_table(sock).get(proxy, (0, ""))[1] == "stopped":
            break
        time.sleep(0.25)
    ctr(sock, "-n", NS, "tasks", "delete", proxy)
    c[proxy]["pid"] = None
    ctr(sock, "-n", NS, "tasks", "start", "-d", idle)
    c[idle]["pid"] = wait_pid(idle)
    import_image(sock, work, t, NEW)
    make(sock, work, t, NEW, True)
    settle(sock, work, t)
    print(describe(t))


def check(sock, work):
    t = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    spaces = sorted(ctr(sock, "namespaces", "ls", "-q").split())
    if spaces != t["namespaces"]:
        bad("the namespaces are %s, not %s" % (" ".join(spaces), " ".join(t["namespaces"])))
    got = live_images(sock)
    if got != t["images"]:
        bad("the images of the namespace %s changed (%d names, there were %d)" % (NS, len(got), len(t["images"])))
    if live_content(sock) != t["content"]:
        bad("the content store of the namespace %s changed" % NS)
    have = sorted(ctr(sock, "-n", NS, "containers", "ls", "-q").split())
    if have != sorted(t["containers"]):
        bad("the containers of %s changed (%d, there were %d)" % (NS, len(have), len(t["containers"])))
    for cid in have:
        if record_hash(sock, cid) != t["records"][cid]:
            bad("the record of the container %s changed" % cid[:12])
    live = task_table(sock)
    for cid, v in t["containers"].items():
        g = live.get(cid)
        if v["pid"] is None:
            if g:
                bad("the container %s has a task (it had none)" % cid[:12])
        elif not g or g[1] != "running" or g[0] != v["pid"]:
            bad("the task of %s is %s, it was running with pid %d" % (cid[:12], g, v["pid"]))


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
