"""lab.py up SOCK WORK | more SOCK WORK | check SOCK WORK : the containers of the node's containerd and what the node must report about them.

The containers are made with `ctr`, as the asker did (no CRI, no pods); the program in every image does nothing and never exits. Four containerd
namespaces are used (bench67990667-shop, -pay, -ops and, after `more`, -edge). The same container ID is in several namespaces as different
containers: web in shop and pay (other images, labels, env, mounts), api in shop, pay and ops (the same image name, other everything else).
up:    shop/web (created, no task), shop/api (running);  pay/web (running), pay/api (created, no task);  ops/api (running), ops/db (created, no task).
       Every container has two random labels (release, owner), two random variables (APP_ID, APP_MODE), and two bind mounts of directories of its
       own, /data read-only and /cfg read-write.
more:  the live state changes, as it does on a node: shop/web gets a task and runs; the process of pay/web is killed (the task stays, it is stopped);
       the task of ops/api is killed and deleted (no task); a new container edge/web runs in a new namespace.
The record, WORK/.bench/truth.json: {"containers": {"NS|ID": {image, runtime, labels, env, mounts: [[dst, src, ro]], status, pid}}, "records": {"NS|ID": sha of
the container's record}}. It comes from what this program created and, for the PID of a task, from the process table of the host (the child of
the container's shim), never from what `ctr` reports about tasks. status is running, stopped (a task whose process has exited) or none (no task); the
pid of a stopped task is the one it had (that is what containerd keeps reporting), the pid of a container without a task is null.
check: fails (one short line) unless the node is as the record says: the same namespaces and containers, every container's record unchanged, and
       exactly the recorded tasks with the recorded PIDs and states (nothing created, started, stopped, removed or relabelled since)."""
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time

HOST = "reg.bench67990667.invalid"
PREFIX = "bench67990667-"
IMAGES = {   # namespace -> image names it holds
    "shop": ["shop/web:1", "shop/api:1"],
    "pay": ["shop/web:2", "shop/api:1"],
    "ops": ["shop/api:1", "shop/db:1"],
}
UP = [   # namespace, container id, image, task
    ("shop", "web", "shop/web:1", False),
    ("shop", "api", "shop/api:1", True),
    ("pay", "web", "shop/web:2", True),
    ("pay", "api", "shop/api:1", False),
    ("ops", "api", "shop/api:1", True),
    ("ops", "db", "shop/db:1", False),
]


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


def key(ns, cid):
    return "%s|%s" % (ns, cid)


def fullns(short):
    return PREFIX + short


def record_hash(sock, ns, cid):
    return hashlib.sha256(ctr(sock, "-n", ns, "containers", "info", cid).encode()).hexdigest()


def import_image(sock, work, ns, name):
    ref = "%s/%s" % (HOST, name)
    tar = path(work, "image.tar")
    subprocess.run([sys.executable, path(work, "mkimg.py"), ref, secrets.token_hex(6), path(work, "idle-bin"), "idle", tar], check=True, capture_output=True)
    os.chmod(tar, 0o644)
    ctr(sock, "-n", ns, "images", "import", tar)
    os.unlink(tar)


def shim_child(ns, cid):
    """the PID of the first process of the container, from the process table: the child of the shim started for (ns, cid)"""
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
                if argv[argv.index(b"-namespace") + 1].decode() == ns and argv[argv.index(b"-id") + 1].decode() == cid:
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


def wait_pid(ns, cid):
    for _ in range(60):
        p = shim_child(ns, cid)
        if p:
            return p
        time.sleep(0.25)
    sys.stderr.write("no process of the container %s in %s\n" % (cid, ns))
    sys.exit(1)


def task_table(sock, ns):
    out = {}
    for line in ctr(sock, "-n", ns, "tasks", "ls").splitlines()[1:]:
        f = line.split()
        if len(f) >= 3:
            out[f[0]] = (int(f[1]), f[2].lower())
    return out


def make(sock, work, t, short, cid, name, task):
    ns = fullns(short)
    ref = "%s/%s" % (HOST, name)
    labels = {"release": "r" + secrets.token_hex(3), "owner": "o" + secrets.token_hex(3)}
    env = {"APP_ID": "id-" + secrets.token_hex(4), "APP_MODE": "m" + secrets.token_hex(3)}
    mounts = []
    args = []
    for k, v in labels.items():
        args += ["--label", "%s=%s" % (k, v)]
    for k, v in env.items():
        args += ["--env", "%s=%s" % (k, v)]
    for dst, ro in (("/data", True), ("/cfg", False)):
        src = os.path.join(work, "mounts", "%s-%s-%s" % (short, cid, dst.strip("/")))
        os.makedirs(src, exist_ok=True)
        os.chmod(src, 0o755)
        mounts.append([dst, src, ro])
        args += ["--mount", "type=bind,src=%s,dst=%s,options=rbind:%s" % (src, dst, "ro" if ro else "rw")]
    if task:
        ctr(sock, "-n", ns, "run", "-d", *args, ref, cid)
        status, pid = "running", wait_pid(ns, cid)
    else:
        ctr(sock, "-n", ns, "containers", "create", *args, ref, cid)
        status, pid = "none", None
    t["containers"][key(ns, cid)] = {
        "image": ref, "runtime": "io.containerd.runc.v2", "labels": labels,
        "env": ["IMAGE_REF=" + ref] + ["%s=%s" % kv for kv in env.items()], "mounts": mounts, "status": status, "pid": pid}


def seal(sock, work, t):
    t["records"] = {k: record_hash(sock, *k.split("|")) for k in t["containers"]}
    t["namespaces"] = sorted({k.split("|")[0] for k in t["containers"]})
    save(work, t)


def describe(t):
    c = t["containers"]
    return "%d containers in %d namespaces, %d running, %d stopped, %d without a task" % (
        len(c), len(t["namespaces"]), sum(v["status"] == "running" for v in c.values()),
        sum(v["status"] == "stopped" for v in c.values()), sum(v["status"] == "none" for v in c.values()))


def up(sock, work):
    t = {"containers": {}, "records": {}, "namespaces": []}
    for short, names in IMAGES.items():
        for name in names:
            import_image(sock, work, fullns(short), name)
    for short, cid, name, task in UP:
        make(sock, work, t, short, cid, name, task)
    seal(sock, work, t)
    print(describe(t))


def more(sock, work):
    t = load(work)
    c = t["containers"]
    shop_web, pay_web, ops_api = (key(fullns(s), i) for s, i in (("shop", "web"), ("pay", "web"), ("ops", "api")))
    ns, cid = shop_web.split("|")
    ctr(sock, "-n", ns, "tasks", "start", "-d", cid)
    c[shop_web].update(status="running", pid=wait_pid(ns, cid))
    ns, cid = pay_web.split("|")
    subprocess.run(["sudo", "kill", "-KILL", str(c[pay_web]["pid"])], check=True)
    for _ in range(60):
        if task_table(sock, ns).get(cid, (0, ""))[1] == "stopped":
            break
        time.sleep(0.25)
    c[pay_web]["status"] = "stopped"
    ns, cid = ops_api.split("|")
    ctr(sock, "-n", ns, "tasks", "kill", "-s", "SIGKILL", cid)
    for _ in range(60):
        if task_table(sock, ns).get(cid, (0, ""))[1] == "stopped":
            break
        time.sleep(0.25)
    ctr(sock, "-n", ns, "tasks", "delete", cid)
    c[ops_api].update(status="none", pid=None)
    import_image(sock, work, fullns("edge"), "shop/web:2")
    make(sock, work, t, "edge", "web", "shop/web:2", True)
    seal(sock, work, t)
    print(describe(t))


def check(sock, work):
    t = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    spaces = sorted(n for n in ctr(sock, "namespaces", "ls", "-q").split())
    if spaces != t["namespaces"]:
        bad("the namespaces are %s, not %s" % (" ".join(s.replace(PREFIX, "") for s in spaces), " ".join(s.replace(PREFIX, "") for s in t["namespaces"])))
    for ns in spaces:
        have = sorted(ctr(sock, "-n", ns, "containers", "ls", "-q").split())
        want = sorted(k.split("|")[1] for k in t["containers"] if k.startswith(ns + "|"))
        if have != want:
            bad("the containers of the namespace %s are %s, not %s" % (ns.replace(PREFIX, ""), " ".join(have), " ".join(want)))
        for cid in want:
            if record_hash(sock, ns, cid) != t["records"][key(ns, cid)]:
                bad("the record of the container %s in %s changed" % (cid, ns.replace(PREFIX, "")))
        live = task_table(sock, ns)
        for cid in want:
            exp = t["containers"][key(ns, cid)]
            got = live.get(cid)
            if exp["status"] == "none":
                if got:
                    bad("the container %s in %s has a task (it had none)" % (cid, ns.replace(PREFIX, "")))
            elif not got or got[1] != exp["status"] or got[0] != exp["pid"]:
                bad("the task of %s in %s is %s, it was %s with pid %d" % (cid, ns.replace(PREFIX, ""), got, exp["status"], exp["pid"]))


if __name__ == "__main__":
    cmd, sock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](sock, work)
