"""lab.py up|more|check DSOCK WORK : the Docker workload of the lab and what runc must report about it.

Docker (a private daemon) runs on its own socket DSOCK. All its settings (exec root with a random name, containerd socket, data root) are in a configuration file, not on its command
line. The daemon runs its containers through a containerd with runc, whose runtime root is EXEC/runtime-runc/moby (one directory per container, with its state.json).
up:    the image bench/app:1 is loaded (`docker load`) and two containers run from it: bench61738905-web and bench61738905-db (the program in the image waits for ever).
more:  the node changes: a container bench61738905-cache starts from the same image and bench61738905-db is removed. web is not touched.
The record, WORK/.bench/truth.json: {"root", "containers": {ID: {name, pid}}}. The ID of a container is what `docker run -d` printed; its PID is what Docker itself says
(`docker inspect`, State.Pid), never what runc says.
check: fails (one short line) unless the node is as the record says: exactly the recorded containers in Docker, every one running with the recorded PID (nothing started, stopped,
       restarted, paused or removed since), and exactly those containers in the runtime root."""
import json
import os
import subprocess
import sys

NAMES = {"web": "bench61738905-web", "db": "bench61738905-db", "cache": "bench61738905-cache"}
RUN = "/run/bench61738905"


def docker(dsock, *args, check=True, timeout=120):
    r = subprocess.run(["docker", "-H", "unix://" + dsock, *args], capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        sys.stderr.write("docker %s failed: %s\n" % (" ".join(args[:4]), r.stderr.strip()[-300:]))
        sys.exit(1)
    return r.stdout.strip()


def path(work, name):
    return os.path.join(work, ".bench", name)


def load(work):
    return json.load(open(path(work, "truth.json")))


def save(work, t):
    json.dump(t, open(path(work, "truth.json"), "w"), indent=1)


def run_container(dsock, t, key):
    cid = docker(dsock, "run", "-d", "--name", NAMES[key], "bench/app:1")
    t["containers"][cid] = {"name": NAMES[key], "pid": int(docker(dsock, "inspect", "-f", "{{.State.Pid}}", cid))}


def held(root):
    r = subprocess.run(["sudo", "ls", root], capture_output=True, text=True)    # the exec root is root's (not readable for the current user)
    return r.returncode, sorted(r.stdout.split())


def up(dsock, work):
    rand = open(path(work, "rand")).read().strip()
    t = {"root": "%s/exec-%s/runtime-runc/moby" % (RUN, rand), "containers": {}}
    docker(dsock, "load", "-i", path(work, "app1.tar"))
    run_container(dsock, t, "web")
    run_container(dsock, t, "db")
    rc, ids = held(t["root"])
    if rc != 0 or ids != sorted(t["containers"]):
        sys.stderr.write("the runtime root %s does not hold the two containers\n" % t["root"])
        sys.exit(1)
    save(work, t)
    print("%d containers running" % len(t["containers"]))


def more(dsock, work):
    t = load(work)
    run_container(dsock, t, "cache")
    db = next(k for k, v in t["containers"].items() if v["name"] == NAMES["db"])
    docker(dsock, "rm", "-f", db)
    del t["containers"][db]
    save(work, t)
    print("%d containers running" % len(t["containers"]))


def check(dsock, work):
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
    for cid, v in t["containers"].items():
        p = int(docker(dsock, "inspect", "-f", "{{.State.Pid}}", cid))
        if p != v["pid"]:
            bad("the process of %s is %s, it was %d (the container was restarted)" % (v["name"], p, v["pid"]))
    rc, ids = held(t["root"])
    if rc != 0 or ids != want:
        bad("the runtime root holds %d containers, the lab left %d" % (len(ids), len(want)))


if __name__ == "__main__":
    cmd, dsock, work = sys.argv[1:4]
    {"up": up, "more": more, "check": check}[cmd](dsock, work)
