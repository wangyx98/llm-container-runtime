"""lab.py controls WORK : the containers of the lab (runc bundles on cgroup v2) and the first control run. Also imported by verify.py.

A container is a runc container of the static program /idle (rootfs /var/lib/bench76608572/rootfs) with a real CPU constraint (linux.resources.cpu.cpus = a set of CPUs of the host) in a cgroup
of its own below /bench76608572-RAND/pod-XXXX/ctr-YYYY (an absolute cgroupsPath whose names do not contain the container ID). Two kinds:
  private  the spec has a cgroup namespace entry (what a normal Kubernetes pod gets on cgroup v2): /sys/fs/cgroup in the container is the container's OWN cgroup;
  host     the spec has no cgroup namespace entry and mounts the cgroup file system read-write (what a privileged pod gets): /sys/fs/cgroup in the container is the HOST's root cgroup.
A container may also be pinned: after it started, its main process gets a CPU affinity of one CPU of its set (so Cpus_allowed_list is smaller than the cgroup's cpuset.cpus.effective).
`facts(c)` reads what the kernel says about a running container (all of it from the host side); `controls WORK` starts one container of each kind with the SAME CPU set, prints the facts and
fails (one short line) unless the symptom is real: the private one has cpuset.cpus at the root of its view and the host one has not, the real allocation being the same for both."""
import json
import os
import random
import secrets
import shutil
import subprocess
import sys

CASE = "bench76608572"
LIB = "/var/lib/" + CASE
ROOTFS = LIB + "/rootfs"
CG = "/sys/fs/cgroup"


def run(*cmd, check=False, timeout=60):
    return subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout, check=check)


def parse(s):
    out = set()
    for part in s.strip().split(","):
        if not part:
            continue
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out


def fmt(cpus):
    cpus = sorted(cpus)
    parts, i = [], 0
    while i < len(cpus):
        j = i
        while j + 1 < len(cpus) and cpus[j + 1] == cpus[j] + 1:
            j += 1
        parts.append(str(cpus[i]) if i == j else "%d-%d" % (cpus[i], cpus[j]))
        i = j + 1
    return ",".join(parts)


def host_cpus():
    """the CPUs the root cgroup may use: the host's own record"""
    return sorted(parse(open(CG + "/cpuset.cpus.effective").read()))


def spec(cgpath, cpus, kind):
    c = json.load(open(LIB + "/config.base.json"))
    c["process"]["args"] = ["/idle"]
    c["process"]["terminal"] = False
    c["root"] = {"path": ROOTFS, "readonly": False}
    c["linux"]["resources"] = {"cpu": {"cpus": fmt(cpus)}}
    c["linux"]["cgroupsPath"] = cgpath
    c["linux"]["namespaces"] = [n for n in c["linux"]["namespaces"] if n["type"] != "cgroup"]
    for m in c["mounts"]:
        if m["destination"] == CG:
            m["options"] = [o for o in m["options"] if o != "ro"]
    if kind == "private":
        c["linux"]["namespaces"].append({"type": "cgroup"})
        for m in c["mounts"]:
            if m["destination"] == CG:
                m["options"] = m["options"] + ["ro"]
    return c


def start(top, cpus, kind, pin=None):
    """starts a container; returns its record {cid, pid, cgdir, cpus, kind, pin, bundle}"""
    cid = "%s-c%s" % (CASE, secrets.token_hex(4))
    cgpath = "/%s/pod-%s/ctr-%s" % (top, secrets.token_hex(4), secrets.token_hex(4))
    bundle = "%s/bundles/%s" % (LIB, cid)
    os.makedirs(bundle)
    json.dump(spec(cgpath, cpus, kind), open(bundle + "/config.json", "w"), indent=1)
    log = bundle + "/runc.log"   # the container's stdio must not be runc's pipes (they would never close): everything goes to /dev/null, runc's own messages to a log
    r = subprocess.run(["runc", "--log", log, "--log-format", "json", "run", "-d", "--bundle", bundle, cid], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=60)
    if r.returncode != 0:
        msgs = [json.loads(x).get("msg", "") for x in open(log).read().splitlines() if x.startswith("{")] if os.path.exists(log) else []
        raise SystemExit("  -> FAIL: the lab could not start a container (runc: %s)" % (msgs[-1] if msgs else "no message")[-200:])
    pid = json.loads(run("runc", "state", cid).stdout)["pid"]
    if pin is not None:
        os.sched_setaffinity(pid, {pin})
    return {"cid": cid, "pid": pid, "cgdir": CG + cgpath, "cpus": sorted(cpus), "kind": kind, "pin": pin, "bundle": bundle}


def stop(c):
    run("runc", "delete", "-f", c["cid"], timeout=60)
    shutil.rmtree(c["bundle"], ignore_errors=True)


def status_field(pid, field):
    for ln in open("/proc/%d/status" % pid):
        if ln.startswith(field + ":"):
            return ln.split(":", 1)[1].strip()
    return ""


def facts(c):
    """what the kernel says about the running container c, read from the host side"""
    pid = c["pid"]
    line = [ln for ln in open("/proc/%d/cgroup" % pid).read().split("\n") if ln.startswith("0::")]
    root_of_view = ""
    for ln in open("/proc/%d/mountinfo" % pid):
        f = ln.split()
        if len(f) > 9 and f[4] == CG and f[f.index("-") + 1] == "cgroup2":
            root_of_view = f[3]
    cpus_file = "/proc/%d/root%s/cpuset.cpus" % (pid, CG)
    return {
        "cid": c["cid"], "pid": pid, "kind": c["kind"],
        "proc_cgroup_line": line[0] if line else "",
        "cgroup_dir_effective": open(c["cgdir"] + "/cpuset.cpus.effective").read().strip() if os.path.isdir(c["cgdir"]) else "",
        "cpus_allowed_list": status_field(pid, "Cpus_allowed_list"),
        "cgroupns": os.readlink("/proc/%d/ns/cgroup" % pid),
        "host_cgroupns": os.readlink("/proc/self/ns/cgroup"),
        "view_mount_root": root_of_view,
        "cpuset_cpus_in_view": open(cpus_file).read().strip() if os.path.exists(cpus_file) else None,
        "view_entries_cpuset": sorted(n for n in os.listdir("/proc/%d/root%s" % (pid, CG)) if n.startswith("cpuset.")),
    }


def choose_sets(allowed):
    """the CPU sets of the four probes of the oracle: two different single CPUs, then two sets with at least two CPUs"""
    a = random.choice(allowed)
    b = random.choice([x for x in allowed if x != a])
    big = lambda: set(random.sample(allowed, random.randint(2, len(allowed))))
    return {a}, {b}, big(), big()


def cleanup_cgroups(top):
    d = CG + "/" + top
    if os.path.isdir(d):
        for root, dirs, _ in os.walk(d, topdown=False):
            try:
                os.rmdir(root)
            except OSError:
                pass


def controls(work):
    allowed = host_cpus()
    if len(allowed) < 2:
        print("  -> FAIL: the host has fewer than two CPUs for the root cgroup (%s)" % fmt(allowed))
        return 1
    top = "%s-%s" % (CASE, secrets.token_hex(3))
    s = set(random.sample(allowed, random.randint(1, len(allowed) - 1)))
    got = {}
    try:
        for kind in ("private", "host"):
            c = start(top, s, kind)
            got[kind] = facts(c)
            got[kind]["cgroup_dir"] = c["cgdir"]
            stop(c)
    finally:
        cleanup_cgroups(top)
    print(json.dumps({"constraint": fmt(s), "host_root_effective": fmt(allowed), "private": got["private"], "host": got["host"]}, indent=1))
    p, h = got["private"], got["host"]
    want = fmt(s)
    probs = []
    if p["cgroup_dir_effective"] != want or h["cgroup_dir_effective"] != want:
        probs.append("the cgroup of the container has cpuset.cpus.effective %s / %s, not the constraint %s" % (p["cgroup_dir_effective"], h["cgroup_dir_effective"], want))
    if p["cpus_allowed_list"] != want or h["cpus_allowed_list"] != want:
        probs.append("Cpus_allowed_list is %s / %s, not the constraint %s" % (p["cpus_allowed_list"], h["cpus_allowed_list"], want))
    if p["cgroupns"] == p["host_cgroupns"] or h["cgroupns"] != h["host_cgroupns"]:
        probs.append("the cgroup namespaces are not as built: private %s, host %s" % (p["cgroupns"], h["cgroupns"]))
    if p["cpuset_cpus_in_view"] != want:
        probs.append("the private container has no cpuset.cpus (or another one) at the root of its /sys/fs/cgroup: %s" % p["cpuset_cpus_in_view"])
    if h["cpuset_cpus_in_view"] is not None:
        probs.append("the host-namespace container has a cpuset.cpus at the root of its /sys/fs/cgroup")
    if probs:
        print("  -> FAIL: " + probs[0])
        return 1
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "controls":
        sys.exit(controls(sys.argv[2]))
    sys.exit("usage: lab.py controls WORK")
