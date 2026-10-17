#!/usr/bin/env python3
"""lab.py : the helpers of the lab of q49877639 (run as root from the root-only state dir by the stage scripts).

  lab.py up WORK        : checks the lab as setup left it and writes the record of what is true (WORK/.bench/truth.json)
  lab.py check WORK     : the lab is as the record says (daemons, plugin installed and disabled)
  lab.py controls WORK  : the question's failure is real (enable fails with its error) and the fix works on this machine (a copy of the plugin directory, repaired, under another name)

The module is also the library of verify.py (the oracle)."""
import json
import os
import re
import shutil
import subprocess
import sys

CASE_ID = "bench49877639"
LIB = "/var/lib/" + CASE_ID
RUN = "/run/" + CASE_ID
DOCK = "unix://" + RUN + "/docker.sock"
CSOCK = RUN + "/containerd.sock"
PLUG = "bench/sysd:1"
SRC = LIB + "/plugin"
DATA = LIB + "/docker"
NS = "plugins.moby"
SOCK_ERR = re.compile(r"sysd\.sock: connect: no such file or directory")

INIT = """#!/bin/sh
# runs as the entrypoint of the plugin, before systemd: keeps the directory of the plugin socket (systemd mounts a tmpfs on /run) and gives systemd the host's cgroups
mkdir -p /dockerplugins
mount --bind /run/docker/plugins /dockerplugins
mount --rbind /hostcgroup /sys/fs/cgroup
exec /usr/lib/systemd/systemd
"""


def run(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ds: %s" % (timeout, " ".join(cmd[:6])))


def docker(*a, timeout=60):
    return run(["docker", "-H", DOCK] + list(a), timeout)


def ctr(*a, timeout=60):
    return run(["ctr", "-a", CSOCK, "-n", NS] + list(a), timeout)


def short(text, n=200):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[:n] + "..."


def errtext(r, n=300):
    """the useful part of a failed command: no warning lines of ctr, the daemon's text"""
    lines = [ln for ln in (r.stderr + "\n" + r.stdout).splitlines() if ln.strip() and "level=warning" not in ln]
    return short(" ".join(lines), n)


def read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def pid_of(pidfile, comm):
    p = (read(pidfile) or "").strip()
    if not p.isdigit() or (read("/proc/%s/comm" % p) or "").strip() != comm:
        return None
    if CASE_ID not in (read("/proc/%s/cmdline" % p) or ""):
        return None
    return int(p)


def identity_problem():
    """None when the daemons that answer are the ones of this lab"""
    if pid_of(RUN + "/containerd.pid", "containerd") is None:
        return "the containerd of the lab is not running (%s/containerd.pid)" % RUN
    if pid_of(RUN + "/docker.pid", "dockerd") is None:
        return "the dockerd of the lab is not running (%s/docker.pid)" % RUN
    r = docker("version", "--format", "{{.Server.Version}}")
    if r.returncode != 0:
        return "the dockerd of the lab does not answer on %s: %s" % (DOCK, errtext(r, 150))
    return None


def plugin_inspect(name=PLUG):
    r = docker("plugin", "inspect", name)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)[0]
    except (ValueError, IndexError):
        return None


def task_pid(plugin_id):
    """host pid of the task of the plugin in containerd, and its status"""
    r = ctr("tasks", "ls")
    for ln in r.stdout.splitlines():
        f = ln.split()
        if len(f) >= 3 and f[0] == plugin_id and f[1].isdigit():
            return int(f[1]), f[2]
    return None, None


def status_field(pid, field):
    for ln in (read("/proc/%d/status" % pid) or "").splitlines():
        if ln.startswith(field + ":"):
            return ln.split(":", 1)[1].split()
    return []


def ppid(pid):
    s = status_field(pid, "PPid")
    return int(s[0]) if s else 0


def ns_ino(pid, kind):
    try:
        return os.stat("/proc/%d/ns/%s" % (pid, kind)).st_ino
    except OSError:
        return None


def cgroup_path(pid):
    """the unified line (0::) when there is one, else the systemd hierarchy"""
    lines = (read("/proc/%d/cgroup" % pid) or "").splitlines()
    for want in ("0::", "name=systemd:"):
        for ln in lines:
            if ln.startswith(want) or (want == "name=systemd:" and ":name=systemd:" in ln):
                return ln.split(":", 2)[2]
    return None


def host_pid_of(inner, pidns):
    """the host pid of the process that is pid INNER in the pid namespace PIDNS"""
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        ns = status_field(int(d), "NSpid")
        if len(ns) > 1 and ns[-1] == str(inner) and ns_ino(int(d), "pid") == pidns:
            return int(d)
    return None


def exec_in(p1, *argv, timeout=30):
    """runs a command inside the namespaces (pid, mount, uts, ipc, cgroup) and the root of the plugin's init P1, like 'docker exec' for a plugin ('ctr tasks exec' into a task whose init is systemd killed the
    task in the lab's tests, nsenter does not)"""
    return run(["nsenter", "-t", str(p1), "-m", "-p", "-u", "-i", "-C", "-r", "-w"] + list(argv), timeout)


def fix_directory(d, sock="/dockerplugins/sysd.sock"):
    """the repair of the question applied to a COPY of the plugin directory (used by the control)"""
    cfg = json.load(open(d + "/config.json"))
    cfg["entrypoint"] = ["/init"]
    cfg["mounts"] = [{"destination": "/hostcgroup", "source": "/sys/fs/cgroup", "type": "bind", "options": ["rbind", "rw", "rprivate"]}]
    json.dump(cfg, open(d + "/config.json", "w"), indent=2)
    with open(d + "/rootfs/init", "w") as f:
        f.write(INIT)
    os.chmod(d + "/rootfs/init", 0o755)
    unit = d + "/rootfs/etc/systemd/system/plugin.service"
    u = read(unit).replace("/run/docker/plugins/sysd.sock", sock)
    with open(unit, "w") as f:
        f.write(u)


def lab_problems(truth=None):
    msg = identity_problem()
    if msg:
        return msg
    info = plugin_inspect()
    if info is None:
        return "the plugin %s is not installed in the lab's Docker" % PLUG
    return None


def cmd_up(work):
    msg = lab_problems()
    if msg:
        print("[lab] " + msg)
        return 1
    ver = (read(work + "/.bench/systemd-version") or "").strip()
    if not ver:
        print("[lab] the version of systemd is not recorded")
        return 1
    info = plugin_inspect()
    if info.get("Enabled"):
        print("[lab] the plugin is enabled before the task starts")
        return 1
    json.dump({"systemd": ver, "plugin": PLUG, "id": info["Id"]}, open(work + "/.bench/truth.json", "w"))
    print("[lab] up: dockerd and containerd of the lab answer, %s installed (disabled), %s" % (PLUG, ver))
    return 0


def cmd_check(work):
    msg = lab_problems()
    if msg:
        print("[lab] " + msg)
        return 1
    truth = json.load(open(work + "/.bench/truth.json"))
    info = plugin_inspect()
    if info["Id"] != truth["id"]:
        print("[lab] the installed plugin is not the one setup installed")
        return 1
    if info.get("Enabled"):
        print("[lab] the plugin is enabled")
        return 1
    cfg = json.load(open(SRC + "/config.json"))
    if cfg.get("entrypoint") != ["/usr/lib/systemd/systemd"]:
        print("[lab] the plugin directory was changed before the task")
        return 1
    return 0


def cmd_controls(work):
    # control 1: the question's failure
    r = docker("plugin", "enable", PLUG, timeout=90)
    if r.returncode == 0:
        print("[lab] control 1: 'docker plugin enable %s' should fail as in the question, but it worked" % PLUG)
        docker("plugin", "disable", "-f", PLUG, timeout=60)
        return 1
    text = errtext(r, 400)
    if not SOCK_ERR.search(text):
        print("[lab] control 1: the enable should fail with 'sysd.sock: connect: no such file or directory', got: " + text)
        return 1
    info = plugin_inspect()
    if info is None or info.get("Enabled"):
        print("[lab] control 1: the plugin should stay installed and disabled")
        return 1
    print("[lab] control 1 ok: enable fails (%s)" % short(text, 120))
    # control 2: the repair works on this machine (a copy of the directory, under another name)
    ctl = work + "/ctl"
    name = "bench/ctl:1"
    shutil.rmtree(ctl, ignore_errors=True)
    r = run(["cp", "-a", SRC, ctl])
    if r.returncode != 0:
        print("[lab] control 2: cannot copy the plugin directory: " + errtext(r))
        return 1
    fix_directory(ctl)
    docker("plugin", "rm", "-f", name)
    try:
        r = docker("plugin", "create", name, ctl, timeout=120)
        if r.returncode != 0:
            print("[lab] control 2: plugin create failed: " + errtext(r))
            return 1
        r = docker("plugin", "enable", name, timeout=90)
        if r.returncode != 0:
            print("[lab] control 2: the repaired plugin does not enable on this machine: " + errtext(r, 400))
            return 1
        r = docker("volume", "create", "-d", name, "vctl")
        ins = docker("volume", "inspect", "vctl")
        try:
            status = json.loads(ins.stdout)[0]["Status"]
        except (ValueError, IndexError, KeyError):
            status = {}
        if r.returncode != 0 or status.get("pid1") != "systemd":
            print("[lab] control 2: the repaired plugin does not run systemd as its init: %s %s" % (errtext(r), short(ins.stdout, 150)))
            return 1
        print("[lab] control 2 ok: the repaired copy runs systemd as PID 1 and the driver answers")
    finally:
        docker("volume", "rm", "-f", "vctl")
        docker("plugin", "disable", "-f", name, timeout=90)
        docker("plugin", "rm", "-f", name)
        shutil.rmtree(ctl, ignore_errors=True)
    return 0


if __name__ == "__main__":
    cmd, work = sys.argv[1], sys.argv[2]
    sys.exit({"up": cmd_up, "check": cmd_check, "controls": cmd_controls}[cmd](work))
