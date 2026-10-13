"""verify.py WORK : the postcondition, from the host's point of view (run as root by oracle.sh with sudo; the script under test runs as the user who called sudo).

Four times, with a NEW container that did not exist when the solution was written (new random CPU sets, new cgroup path, new ID and PID), the lab starts a runc container with a real cpuset
constraint, runs `bash WORK/cpu-report.sh TARGET OUTPUT_FILE` (TARGET is the host PID of the container's main process, or the runc container ID) and compares the JSON object it wrote with
what the lab knows from the other side:
  1 private cgroup namespace, one CPU, target = PID;  2 host cgroup namespace (privileged-style), another single CPU, target = container ID;
  3 private, a set of >= 2 CPUs, main process pinned to one of them, target = container ID;  4 host cgroup namespace, a set of >= 2 CPUs, pinned, target = PID.
Truth per probe: cgroup_dir = /sys/fs/cgroup + the path of the `0::` line of the host's /proc/PID/cgroup (which must be the cgroupsPath the lab gave runc); effective_cpus = the CPU set of the
constraint = cpuset.cpus.effective of that directory (not Cpus_allowed_list, which is smaller when pinned, and not the host root's); view_root_dir = the cgroup directory itself for a private
namespace, /sys/fs/cgroup for the host's; view_shows_own_cgroup and cpuset_cpus_in_view = True for private, False for host. After each run the lab checks that the container is still as it was
(running, same cgroup, same CPUs, same affinity, nothing else started), so the script has only read. Prints one short line for the first thing that is wrong (variable details last) and
exits 1, or one line and exits 0."""
import json
import os
import random
import secrets
import subprocess
import sys

work = sys.argv[1]
bench = os.path.join(work, ".bench")
sys.path.insert(0, bench)
import lab   # noqa: E402

CG = lab.CG


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


def run_script(target, out):
    cmd = ["bash", os.path.join(work, "cpu-report.sh"), target, out]
    user = os.environ.get("SUDO_USER")
    if user and user != "root":
        cmd = ["sudo", "-n", "-u", user, "-H"] + cmd
    try:
        return subprocess.run(cmd, cwd=work, capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        fail("the script did not finish in 90 s")


if not os.path.isfile(os.path.join(work, "cpu-report.sh")):
    fail("there is no %s/cpu-report.sh" % work)
allowed = lab.host_cpus()
if len(allowed) < 2:
    fail("lab error: the host has fewer than two CPUs")
sets = lab.choose_sets(allowed)
top = "%s-%s" % (lab.CASE, secrets.token_hex(3))
probes = [("private", sets[0], False, "pid"), ("host", sets[1], False, "cid"), ("private", sets[2], True, "cid"), ("host", sets[3], True, "pid")]
live = []
noted = []
try:
    for n, (kind, cpus, pinned, how) in enumerate(probes, 1):
        pin = random.choice(sorted(cpus)) if pinned else None
        c = lab.start(top, cpus, kind, pin)
        live.append(c)
        pid = c["pid"]
        where = "container %d (%s cgroup namespace, CPUs %s%s, given as %s)" % (
            n, "private" if kind == "private" else "host", lab.fmt(cpus), ", main process pinned to CPU %d" % pin if pinned else "", "PID" if how == "pid" else "container ID")
        # what the lab knows, independently of the script
        line = [ln for ln in open("/proc/%d/cgroup" % pid).read().split("\n") if ln.startswith("0::")]
        if not line or CG + line[0][3:] != c["cgdir"]:
            fail("lab error: the host says the cgroup of %s is %s" % (where, line[0] if line else "nothing"))
        if open(c["cgdir"] + "/cpuset.cpus.effective").read().strip() != lab.fmt(cpus):
            fail("lab error: cpuset.cpus.effective of %s is not the constraint" % where)
        allowed_list = lab.status_field(pid, "Cpus_allowed_list")
        if allowed_list != (str(pin) if pinned else lab.fmt(cpus)):
            fail("lab error: Cpus_allowed_list of %s is %s" % (where, allowed_list))
        own = kind == "private"
        want = {"cgroup_dir": c["cgdir"], "effective_cpus": lab.fmt(cpus), "view_root_dir": c["cgdir"] if own else CG,
                "view_shows_own_cgroup": own, "cpuset_cpus_in_view": own}
        out = os.path.join(work, "out-%d-%s.json" % (n, secrets.token_hex(3)))
        r = run_script(str(pid) if how == "pid" else c["cid"], out)
        if r.returncode != 0:
            fail("the script exits with status %d for %s: %s" % (r.returncode, where, ((r.stderr.strip() or r.stdout.strip()).split("\n") or [""])[-1][-160:]))
        if not os.path.isfile(out):
            fail("the script wrote no output file for %s" % where)
        try:
            data = json.load(open(out))
        except ValueError as e:
            fail("the output for %s is not JSON: %s" % (where, str(e)[:100]))
        if not isinstance(data, dict):
            fail("the output for %s is not a JSON object" % where)
        miss = [k for k in want if k not in data]
        if miss:
            fail("the output for %s has no key %s (it has: %s)" % (where, miss[0], " ".join(sorted(data))[:100]))
        for k in ("view_shows_own_cgroup", "cpuset_cpus_in_view"):
            if not isinstance(data[k], bool):
                fail("%s is not true or false for %s: %s" % (k, where, str(data[k])[:60]))
        # the real allocation
        try:
            got_cpus = lab.parse(str(data["effective_cpus"]))
        except ValueError:
            fail("effective_cpus is not a CPU list for %s: %s" % (where, str(data["effective_cpus"])[:60]))
        if str(data["cgroup_dir"]).rstrip("/") != want["cgroup_dir"]:
            fail("the cgroup of %s is %s; the script says %s" % (where, want["cgroup_dir"], str(data["cgroup_dir"])[:140]))
        if got_cpus != set(cpus):
            fail("%s may really use the CPUs %s; the script says %s" % (where, want["effective_cpus"], str(data["effective_cpus"])[:60]))
        # the two views
        if data["cpuset_cpus_in_view"] != want["cpuset_cpus_in_view"]:
            fail("cpuset_cpus_in_view for %s should be %s; the script says %s" % (where, str(own).lower(), str(data["cpuset_cpus_in_view"]).lower()))
        if str(data["view_root_dir"]).rstrip("/") != want["view_root_dir"]:
            fail("the directory %s sees as /sys/fs/cgroup is %s; the script says %s" % (where, want["view_root_dir"], str(data["view_root_dir"])[:140]))
        if data["view_shows_own_cgroup"] != own:
            fail("view_shows_own_cgroup for %s should be %s; the script says %s" % (where, str(own).lower(), str(data["view_shows_own_cgroup"]).lower()))
        # the script only read
        names = {x["cid"] for x in live}
        listed = {x["id"] for x in (json.loads(lab.run("runc", "list", "--format", "json").stdout or "null") or []) if x["id"].startswith(lab.CASE)}
        if listed != names:
            fail("after the script the containers of the lab are %d, not %d" % (len(listed), len(names)))
        if lab.status_field(pid, "Cpus_allowed_list") != allowed_list or open(c["cgdir"] + "/cpuset.cpus").read().strip() != lab.fmt(cpus):
            fail("the script changed the CPUs of %s" % where)
        noted.append("%s%s" % ("P" if own else "H", lab.fmt(cpus)))
        lab.stop(c)
        live.remove(c)
finally:
    for c in live:
        lab.stop(c)
    lab.cleanup_cgroups(top)
print("  -> OK: 4 new containers (%s: private/host namespace, CPU sets, PID and container ID as the target): the real CPU set, the cgroup directory and both views right" % " ".join(noted))
