#!/usr/bin/env python3
"""verify.py WORK : the oracle of q49877639 (run as root by oracle.sh).

The lab's dockerd and containerd are the processes of setup. Phase A, the plugin as the solution left it: bench/sysd:1 is enabled and its task in the lab's containerd is running; the init (PID 1)
of that task is a systemd, a file of the plugin's rootfs, in PID and mount namespaces of its own (not the host's systemd); the systemd of the plugin is the version setup recorded and says
that a unit is active; a volume made through the plugin's driver answers with the pid of the driver process, the name of PID 1 and the INVOCATION_ID of its unit; that process is, on the host,
a descendant of the task's PID 1 (never of the host's PID 1), sits in a cgroup below the plugin's own (…/system.slice/UNIT), is the MainPID of that active unit and has the invocation id in its
environment. Phase B: `docker plugin disable` and `enable` (a new task from the configuration alone) and the same checks."""
import os
import re
import secrets
import sys

import lab


def fail(msg):
    print("[verify] FAIL: " + msg)
    sys.exit(1)


def sysctl(p1, *argv):
    r = lab.exec_in(p1, "/usr/bin/systemctl", *argv)
    return r.returncode, (r.stdout or "").strip(), lab.errtext(r, 160)


def check_running(truth, tag):
    """returns the first problem as text, or None"""
    msg = lab.identity_problem()
    if msg:
        return msg
    info = lab.plugin_inspect()
    if info is None:
        return "the plugin %s is not installed" % lab.PLUG
    if not info.get("Enabled"):
        return "the plugin %s is installed but not enabled" % lab.PLUG
    types = (info.get("Config", {}).get("Interface", {}) or {}).get("Types") or []
    if not any("volumedriver" in str(t) for t in types):
        return "the plugin %s does not declare a volume driver interface" % lab.PLUG
    pid_id = info["Id"]
    p1, status = lab.task_pid(pid_id)
    if p1 is None or status != "RUNNING":
        return "the plugin has no running task in the lab's containerd (status %s)" % status
    comm = (lab.read("/proc/%d/comm" % p1) or "").strip()
    if comm != "systemd":
        return "PID 1 of the plugin is '%s', not systemd" % comm
    rootfs = "%s/plugins/%s/rootfs" % (lab.DATA, pid_id)
    try:
        exe = os.readlink("/proc/%d/exe" % p1)
        same = os.path.samefile("/proc/%d/exe" % p1, rootfs + exe)
    except OSError:
        same = False
    if not same:
        return "PID 1 of the plugin does not run a systemd file of the plugin's rootfs"
    nspid = lab.status_field(p1, "NSpid")
    if not nspid or nspid[-1] != "1":
        return "the init of the plugin is not PID 1 of a PID namespace of its own"
    for kind in ("pid", "mnt"):
        if lab.ns_ino(p1, kind) in (None, lab.ns_ino(1, kind)):
            return "the plugin shares the %s namespace of the host" % kind
    rc, ver, err = sysctl(p1, "--version")
    if rc != 0 or ver.splitlines()[0] != truth["systemd"]:
        return "the systemd of the plugin is not the recorded one (%s): %s" % (truth["systemd"], lab.short(ver or err, 120))

    vol = "v" + secrets.token_hex(4)
    r = lab.docker("volume", "create", "-d", lab.PLUG, vol)
    if r.returncode != 0:
        return "the volume driver does not answer: " + lab.errtext(r, 200)
    try:
        ins = lab.docker("volume", "inspect", vol)
        import json
        st = (json.loads(ins.stdout)[0].get("Status") or {}) if ins.returncode == 0 else {}
    except (ValueError, IndexError):
        st = {}
    finally:
        lab.docker("volume", "rm", "-f", vol)
    if st.get("pid1") != "systemd" or not str(st.get("pid", "")).isdigit():
        return "the driver reports no PID 1 'systemd' and a pid (Status: %s)" % lab.short(str(st), 120)
    if not re.fullmatch(r"[0-9a-f]{32}", st.get("invocation_id", "")):
        return "the driver process has no INVOCATION_ID: it was not started by a systemd unit"
    h = lab.host_pid_of(int(st["pid"]), lab.ns_ino(p1, "pid"))
    if h is None:
        return "the driver process (pid %s in the plugin) is not found in the plugin's PID namespace" % st["pid"]
    chain, p = [], h
    while p > 1 and p != p1 and len(chain) < 64:
        chain.append(p)
        p = lab.ppid(p)
    if p != p1:
        return "the driver process is not a descendant of the plugin's PID 1 (host pid %d)" % h
    cg, cg1 = lab.cgroup_path(h), lab.cgroup_path(p1)
    base = re.sub(r"/init\.scope$", "", cg1 or "")
    m = re.search(r"/([^/]+\.service)$", cg or "")
    if not cg or not m or not cg.startswith(base + "/") or "/system.slice/" not in cg:
        return "the driver process is not in a cgroup of a service below the plugin's own (it is in %s, the plugin's init in %s)" % (cg, cg1)
    unit = m.group(1)
    rc, act, err = sysctl(p1, "is-active", unit)
    if rc != 0 or act != "active":
        return "the unit %s is not active in the plugin's systemd: %s" % (unit, lab.short(act or err, 120))
    rc, main, err = sysctl(p1, "show", "-p", "MainPID", "--value", unit)
    if main != st["pid"]:
        return "the driver process is not the MainPID of %s (%s, driver pid %s)" % (unit, main or err, st["pid"])
    rc, inv, err = sysctl(p1, "show", "-p", "InvocationID", "--value", unit)
    if inv != st["invocation_id"]:
        return "the driver's INVOCATION_ID (%s) is not the invocation id of %s (%s)" % (st["invocation_id"][:8], unit, (inv or err)[:8])
    env = (lab.read("/proc/%d/environ" % h) or "").split("\0")
    if "INVOCATION_ID=" + inv not in env:
        return "the environment of the driver process does not carry the invocation id of %s" % unit
    print("[verify] %s ok: %s runs systemd as PID 1 (host pid %d), %s is active, its driver (pid %s, host %d) answers" % (tag, lab.PLUG, p1, unit, st["pid"], h))
    return None


def main(work):
    import json
    truth = json.load(open(work + "/.bench/truth.json"))
    msg = check_running(truth, "phase A")
    if msg:
        fail("phase A (plugin as left): " + msg)
    before = lab.task_pid(lab.plugin_inspect()["Id"])[0]
    r = lab.docker("plugin", "disable", lab.PLUG, timeout=120)
    if r.returncode != 0:
        fail("'docker plugin disable %s' failed: %s" % (lab.PLUG, lab.errtext(r, 200)))
    r = lab.docker("plugin", "enable", lab.PLUG, timeout=120)
    if r.returncode != 0:
        fail("after 'docker plugin disable', 'docker plugin enable %s' fails: %s" % (lab.PLUG, lab.errtext(r, 300)))
    msg = check_running(truth, "phase B")
    if msg:
        fail("phase B (after disable and enable): " + msg)
    after = lab.task_pid(lab.plugin_inspect()["Id"])[0]
    if before == after:
        fail("phase B: the plugin's task is the same process as before the restart")
    print("[verify] done: systemd runs as the init of the plugin, as left and again after disable and enable")


if __name__ == "__main__":
    main(sys.argv[1])
