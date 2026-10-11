"""lab.py up|more|check DSOCK CSOCK EXECROOT WORK : the Docker workload of the lab and what the node must report about it.

Docker (a private daemon) runs on its own socket DSOCK, with an exec root EXECROOT and the containerd at CSOCK, both with random names chosen at setup. The
daemon keeps its images in containerd (the containerd image store), in the containerd namespace moby, and runs its containers through that containerd with
runc, whose runtime root is EXECROOT/runtime-runc/moby (one directory per container, with its state.json).
up:    the image bench/app:1 is loaded (`docker load`) and two containers run from it: bench57009928-web and bench57009928-db (the program in the image waits for
       ever).
more:  the node changes: the image bench/tool:2 is loaded, a container bench57009928-cache runs from it, and bench57009928-db is removed. web is not touched.
The record, WORK/.bench/truth.json: {"root", "socket", "namespace", "containers": {ID: {name, pid}}, "images": {REF: DIGEST}}. The ID of a container is what `docker run -d`
printed; its PID comes from the process table of the host (the child of the container's shim), never from runc, ctr or docker; the digest of an image is what the
containerd of the node reports once, after the load (and the Docker daemon agrees on it).
check: fails (one short line) unless the node is as the record says: exactly the recorded containers in Docker and in containerd, every one running with the recorded
       PID, and exactly the recorded images (nothing started, stopped, restarted, paused, removed, pulled or loaded since)."""
import json
import os
import subprocess
import sys
import time

NS = "moby"
NAMES = {"web": "bench57009928-web", "db": "bench57009928-db", "cache": "bench57009928-cache"}


def docker(dsock, *args, check=True, timeout=120):
    r = subprocess.run(["docker", "-H", "unix://" + dsock, *args], capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        sys.stderr.write("docker %s failed: %s\n" % (" ".join(args[:4]), r.stderr.strip()[-300:]))
        sys.exit(1)
    return r.stdout.strip()


def ctr(csock, *args, check=True):
    r = subprocess.run(["sudo", "ctr", "-a", csock, *args], capture_output=True, text=True, timeout=60)
    if check and r.returncode != 0:
        sys.stderr.write("ctr %s failed: %s\n" % (" ".join(args[:5]), r.stderr.strip()[-300:]))
        sys.exit(1)
    return r.stdout


def path(work, name):
    return os.path.join(work, ".bench", name)


def load(work):
    return json.load(open(path(work, "truth.json")))


def live_images(csock):
    out = {}
    for line in ctr(csock, "-n", NS, "images", "ls").splitlines()[1:]:
        f = line.split()
        if f:
            out[f[0]] = f[2]
    return out


def shim_child(cid):
    """the PID of the first process of the container, from the process table: the child of the shim started for (moby, cid)"""
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
    sys.stderr.write("no process of the container %s\n" % cid[:12])
    sys.exit(1)


def run_container(dsock, t, key, ref):
    cid = docker(dsock, "run", "-d", "--name", NAMES[key], ref)
    t["containers"][cid] = {"name": NAMES[key], "pid": wait_pid(cid)}


def record_images(dsock, csock, t, ref):
    live = live_images(csock)
    full = "docker.io/" + ref
    if full not in live:
        sys.stderr.write("the image %s is not in the containerd namespace %s: this Docker keeps its images outside containerd (it needs the containerd image store)\n" % (ref, NS))
        sys.exit(1)
    if docker(dsock, "image", "inspect", "-f", "{{.Id}}", ref) != live[full]:
        sys.stderr.write("Docker and containerd disagree about the digest of %s\n" % ref)
        sys.exit(1)
    t["images"] = live


def describe(t):
    return "%d containers running, %d images in containerd" % (len(t["containers"]), len(t["images"]))


def up(dsock, csock, execroot, work):
    t = {"root": os.path.join(execroot, "runtime-runc", NS), "socket": csock, "namespace": NS, "containers": {}, "images": {}}
    docker(dsock, "load", "-i", path(work, "app1.tar"))
    record_images(dsock, csock, t, "bench/app:1")
    run_container(dsock, t, "web", "bench/app:1")
    run_container(dsock, t, "db", "bench/app:1")
    held = subprocess.run(["sudo", "ls", t["root"]], capture_output=True, text=True)       # the exec root is root's (not readable for the current user)
    if held.returncode != 0 or sorted(held.stdout.split()) != sorted(t["containers"]):
        sys.stderr.write("the runtime root %s does not hold the two containers\n" % t["root"])
        sys.exit(1)
    json.dump(t, open(path(work, "truth.json"), "w"), indent=1)
    print(describe(t))


def more(dsock, csock, execroot, work):
    t = load(work)
    docker(dsock, "load", "-i", path(work, "tool2.tar"))
    record_images(dsock, csock, t, "bench/tool:2")
    run_container(dsock, t, "cache", "bench/tool:2")
    db = next(k for k, v in t["containers"].items() if v["name"] == NAMES["db"])
    docker(dsock, "rm", "-f", db)
    del t["containers"][db]
    json.dump(t, open(path(work, "truth.json"), "w"), indent=1)
    print(describe(t))


def check(dsock, csock, execroot, work):
    t = load(work)

    def bad(msg):
        print("the node is not as the lab left it: " + msg)
        sys.exit(1)
    want = sorted(t["containers"])
    have = sorted(docker(dsock, "ps", "-aq", "--no-trunc").split())
    if have != want:
        bad("Docker has %d containers (%d running), the lab left %d" % (len(have), len(docker(dsock, "ps", "-q").split()), len(want)))
    if sorted(docker(dsock, "ps", "-q", "--no-trunc").split()) != want:
        bad("not every container of Docker is running")
    inctr = sorted(ctr(csock, "-n", NS, "containers", "ls", "-q").split())
    if inctr != want:
        bad("containerd has %d containers in the namespace %s, the lab left %d" % (len(inctr), NS, len(want)))
    for cid, v in t["containers"].items():
        p = shim_child(cid)
        if p != v["pid"]:
            bad("the process of %s is %s, it was %d (the container was restarted or stopped)" % (v["name"], p, v["pid"]))
    got = live_images(csock)
    if got != t["images"]:
        bad("the images of the namespace %s changed (%d, there were %d)" % (NS, len(got), len(t["images"])))


if __name__ == "__main__":
    cmd, dsock, csock, execroot, work = sys.argv[1:6]
    {"up": up, "more": more, "check": check}[cmd](dsock, csock, execroot, work)
