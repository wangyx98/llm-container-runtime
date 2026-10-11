#!/usr/bin/env python3
"""lab.py up|more|check WORK : the containers of the case, the commands that make them work, and the record of what they did.

  up     starts two bare runc containers from one OCI bundle each (a rootfs with the static program /app and a bind mount of a control directory at /ctl):
         bench64071782-job and bench64071782-app. In each the first process (`app init`) only sleeps and its child (`app burn`) uses CPU time when told to. Both cgroups
         are below one random parent (/bench64071782-RAND/ID), so neither the path nor the parent can be guessed. The record WORK/.bench/truth.json holds, for each container,
         the ID, the PID of its first process (as `runc state` says), the start times of the first process and the worker, the cgroup the kernel says the first process is in
         (/proc/PID/cgroup: the cpuacct hierarchy of cgroup v1, the unified one of v2), and the CPU time the worker has reported using (burned_ns).
  more   starts a third container, bench64071782-more-RAND, WITHOUT a cgroupsPath (runc chooses the path itself: another place than the first two).
  check  every recorded container is still running with the same first process and worker (same PIDs and start times) and in the same cgroup.

Used by verify.py as a module: burn(), counter(), init_cpu_ns(), cgroup_of(), hierarchy()."""
import json
import os
import secrets
import subprocess
import sys
import time

CASE = "bench64071782"
LIB = "/var/lib/" + CASE


def sudo(*cmd, **kw):
    return subprocess.run(["sudo", *cmd], **kw)


def read_stat(pid):
    """(state, ppid, utime+stime in clock ticks, start time in ticks) of a process"""
    data = open("/proc/%d/stat" % pid).read()
    f = data[data.rindex(")") + 2:].split()
    return f[0], int(f[1]), int(f[11]) + int(f[12]), int(f[19])


def hierarchy():
    """('v1', mount point of the cpuacct hierarchy) or ('v2', mount point of the unified hierarchy)"""
    v2 = None
    for line in open("/proc/self/mountinfo"):
        left, right = line.split(" - ", 1)
        fs, _, opts = right.split()[:3]
        if fs == "cgroup" and "cpuacct" in opts.split(","):
            return "v1", left.split()[4]
        if fs == "cgroup2" and v2 is None:
            v2 = left.split()[4]
    return "v2", v2


def cgroup_of(pid):
    """the cgroup of a process as /proc/PID/cgroup shows it: the line of the cpuacct controller (v1) or the unified line (v2)"""
    kind = hierarchy()[0]
    for line in open("/proc/%d/cgroup" % pid):
        _, ctrl, path = line.rstrip("\n").split(":", 2)
        if (kind == "v2" and ctrl == "") or (kind == "v1" and "cpuacct" in ctrl.split(",")):
            return path
    raise RuntimeError("no cgroup line for the CPU accounting in /proc/%d/cgroup" % pid)


def counter(path):
    """the CPU time (ns) the kernel has counted for the cgroup `path`: cpuacct.usage (v1) or usage_usec of cpu.stat (v2)"""
    kind, mount = hierarchy()
    d = mount + path
    if kind == "v1":
        return int(open(d + "/cpuacct.usage").read())
    for line in open(d + "/cpu.stat"):
        k, v = line.split()
        if k == "usage_usec":
            return int(v) * 1000
    raise RuntimeError("no usage_usec in " + d + "/cpu.stat")


def init_cpu_ns(pid):
    """the CPU time of ONE process (/proc/PID/stat, in ticks) in ns"""
    return read_stat(pid)[2] * 1000000000 // os.sysconf("SC_CLK_TCK")


def paths(work):
    bench = os.path.join(work, ".bench")
    return bench, os.path.join(bench, "truth.json"), os.path.join(bench, "ids.txt")


def load(work):
    return json.load(open(paths(work)[1]))


def save(work, truth):
    p = paths(work)[1]
    with open(p + ".tmp", "w") as f:
        json.dump(truth, f)
    os.replace(p + ".tmp", p)


def state(cid):
    r = sudo("runc", "state", cid, capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 else None


def start(work, name, cid, cgroups_path):
    bench = paths(work)[0]
    bundle = "%s/%s" % (LIB, name)
    spec = os.path.join(bench, "spec-" + name)
    os.makedirs(spec, exist_ok=True)
    subprocess.run(["runc", "spec"], cwd=spec, check=True)
    cfg = json.load(open(os.path.join(spec, "config.json")))
    cfg["process"]["terminal"] = False
    cfg["process"]["args"] = ["/app", "init"]
    cfg["root"]["readonly"] = True
    cfg["mounts"].append({"destination": "/ctl", "type": "bind", "source": os.path.join(bench, "ctl", name), "options": ["rbind", "rw"]})
    if cgroups_path:
        cfg["linux"]["cgroupsPath"] = cgroups_path
    json.dump(cfg, open(os.path.join(spec, "config.json"), "w"), indent=1)
    ctl = os.path.join(bench, "ctl", name)
    os.makedirs(ctl, exist_ok=True)
    os.chmod(ctl, 0o777)        # the worker is root of the container but has no capability that overrides the owner: the directory belongs to the user who runs the lab
    sudo("mkdir", "-p", bundle + "/rootfs", check=True)
    sudo("cp", os.path.join(bench, "app"), bundle + "/rootfs/app", check=True)
    sudo("install", "-m", "644", os.path.join(spec, "config.json"), bundle + "/config.json", check=True)
    with open(os.path.join(bench, "runc-%s.log" % name), "w") as log:
        r = sudo("runc", "run", "-d", "--bundle", bundle, cid, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    st = None
    for _ in range(100):
        st = state(cid)
        if st and st["status"] == "running":
            break
        time.sleep(0.1)
    if not st or st["status"] != "running":
        raise SystemExit("the container %s did not start (runc run says %d: %s)" % (cid, r.returncode, open(os.path.join(bench, "runc-%s.log" % name)).read()[-200:].strip()))
    pid = st["pid"]
    worker = None
    for _ in range(100):
        kids = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
        if kids:
            worker = int(kids[0])
            break
        time.sleep(0.1)
    if worker is None:
        raise SystemExit("the container %s has no worker process" % cid)
    return {"id": cid, "pid": pid, "start": read_stat(pid)[3], "worker": worker, "worker_start": read_stat(worker)[3], "cgroup": cgroup_of(pid), "burned_ns": 0}


def up(work):
    bench, _, ids = paths(work)
    rand = secrets.token_hex(4)
    open(os.path.join(bench, "rand"), "w").write(rand)
    parent = "/%s-%s" % (CASE, rand)
    cids = {"job": CASE + "-job", "app": CASE + "-app"}
    with open(ids, "w") as f:                                   # recorded BEFORE anything starts: cleanup removes exactly these
        f.write("\n".join(cids.values()) + "\n")
    truth = {"containers": {}}
    for name in ("job", "app"):                                 # job first: its processes have the lower PIDs, so "the first process called app" is not the target's
        truth["containers"][name] = start(work, name, cids[name], "%s/%s" % (parent, cids[name]))
    save(work, truth)


def more(work):
    bench, _, ids = paths(work)
    cid = "%s-more-%s" % (CASE, secrets.token_hex(3))
    with open(ids, "a") as f:
        f.write(cid + "\n")
    truth = load(work)
    truth["containers"]["more"] = start(work, "more", cid, None)
    save(work, truth)


def burn(work, name, ms):
    """tell the worker of the container to use `ms` ms of CPU time; returns the CPU time (ns) it says it used, and adds it to the record"""
    ctl = os.path.join(paths(work)[0], "ctl", name)
    done = os.path.join(ctl, "done")
    if os.path.exists(done):
        os.unlink(done)
    with open(os.path.join(ctl, "burn.tmp"), "w") as f:
        f.write("%d\n" % ms)
    os.rename(os.path.join(ctl, "burn.tmp"), os.path.join(ctl, "burn"))
    for _ in range(int((ms / 1000 + 20) / 0.02)):
        if os.path.exists(done):
            used = int(open(done).read().strip())
            truth = load(work)
            truth["containers"][name]["burned_ns"] += used
            save(work, truth)
            return used
        time.sleep(0.02)
    raise SystemExit("the worker of %s did not answer in %d s" % (name, ms // 1000 + 20))


def check(work):
    truth = load(work)
    for name, c in truth["containers"].items():
        st = state(c["id"])
        if not st:
            raise SystemExit("the container %s is gone" % c["id"])
        if st["status"] != "running":
            raise SystemExit("the container %s is %s, not running" % (c["id"], st["status"]))
        if st["pid"] != c["pid"] or read_stat(c["pid"])[3] != c["start"]:
            raise SystemExit("the container %s was restarted (its first process is not the one of the lab)" % c["id"])
        try:
            w = read_stat(c["worker"])
        except OSError:
            raise SystemExit("the worker of %s is gone" % c["id"])
        if w[3] != c["worker_start"]:
            raise SystemExit("the worker of %s is not the one of the lab" % c["id"])
        if cgroup_of(c["pid"]) != c["cgroup"]:
            raise SystemExit("the container %s was moved to another cgroup: %s" % (c["id"], cgroup_of(c["pid"])))


if __name__ == "__main__":
    cmd, work = sys.argv[1:3]
    {"up": up, "more": more, "check": check}[cmd](work)
