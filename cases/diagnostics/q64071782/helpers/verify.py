"""verify.py WORK first|second : run the solution's script against containers that work and idle, and compare what it reports with what the lab knows.

It runs `bash WORK/cpu-usage.sh ID OUTPUT_FILE` (a new path each time) and reads {"cgroup", "usage_ns"}. The truth is not taken from any tool the solution may use: the cgroup is the
one the kernel shows for the first process of the container (/proc/PID/cgroup), and the CPU time a container has used is what its worker process says it used (its own
CPU clock, written to the control file when the lab told it to work) -- so a counter that follows the container must grow by exactly that, and by nothing while the container idles.

first : (1) bench64071782-app is read, then ONLY bench64071782-job works (250 ms), then app is read again: its counter must not move (a counter that includes the other container, e.g. the
        parent cgroup of both, grows); (2) app works 300 ms: the counter must grow by that (and not by 0: the first process only sleeps, and not by a factor 1000: units); (3) app works
        150 ms: the same, and the value must be the whole CPU time since the container started (at least all the CPU time its worker has reported). Every reading names the right cgroup.
second: (lab.py more has started a container with an ID and a cgroup path the script has not seen) it is read, works 300 ms and is read again: the same checks, and the cgroup is its own;
        then app is read once more: nothing moved there.
Prints one short line for the first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import subprocess
import sys

work, phase = sys.argv[1:3]
bench = os.path.join(work, ".bench")
sys.path.insert(0, bench)
import lab  # noqa: E402

CASE = "bench64071782"
IDLE_MAX = 50_000_000         # a container that does not work may count this much (its worker wakes up every 10 ms, the processes were started)
OVER_MAX = 80_000_000         # on top of the work: the polling of the worker during the window
UNDER_MAX = 1_000_000         # the counter is exact: it cannot grow by less than the worker used (1 ms of room for the unit of cpu.stat)
TOTAL_OVER = 1_500_000_000    # all the CPU time since start may be more than the worker's reports by the start of the container and its polling
n_read = [0]


def fail(msg):
    print("  -> FAIL: %s" % msg)
    sys.exit(1)


def ms(ns):
    return "%.1f ms" % (ns / 1e6)


def keep():
    c = subprocess.run([sys.executable, os.path.join(bench, "lab.py"), "check", work], capture_output=True, text=True)
    if c.returncode != 0:
        fail((c.stdout.strip() or c.stderr.strip())[-300:])


def read(name):
    """run the script for the container `name` and return (usage_ns, cgroup) after checking the cgroup"""
    truth = lab.load(work)
    c = truth["containers"][name]
    n_read[0] += 1
    out = os.path.join(work, "out-%s-%d.json" % (phase, n_read[0]))
    try:
        r = subprocess.run(["bash", os.path.join(work, "cpu-usage.sh"), c["id"], out], cwd=work, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        fail("the script did not finish in 60 s")
    if r.returncode != 0:
        fail("the script exits with status %d for %s: %s" % (r.returncode, c["id"], (r.stderr.strip() or r.stdout.strip())[-200:]))
    if not os.path.isfile(out):
        fail("the script wrote no output file for " + c["id"])
    try:
        data = json.load(open(out))
    except ValueError as e:
        fail("the output is not JSON: %s" % str(e)[:100])
    if not isinstance(data, dict):
        fail("the output is not a JSON object")
    for k in ("cgroup", "usage_ns"):
        if k not in data:
            fail("the output has no key %s (it has: %s)" % (k, " ".join(sorted(data))[:100]))
    if not isinstance(data["cgroup"], str):
        fail("cgroup is not a string: %s" % json.dumps(data["cgroup"])[:80])
    u = data["usage_ns"]
    if isinstance(u, bool) or not isinstance(u, int):
        fail("usage_ns is not an integer: %s" % json.dumps(u)[:80])
    cg = data["cgroup"] if data["cgroup"] == "/" else data["cgroup"].rstrip("/")
    if cg != c["cgroup"]:
        others = [o["id"] for k, o in truth["containers"].items() if k != name and o["cgroup"] == cg]
        hint = " (that is the cgroup of %s)" % others[0] if others else ""
        fail("the cgroup of %s is %s; the script says %s%s" % (c["id"], c["cgroup"], data["cgroup"], hint))
    return u, c


def grew(name, before, after, used, note=""):
    """after a window in which `name` used `used` ns of CPU time: the counter must have grown by that"""
    d = after - before
    c = lab.load(work)["containers"][name]
    if d < used - UNDER_MAX:
        hint = ""
        if abs(d * 1000 - used) <= used // 5 + 1_000_000:
            hint = " (the number is in microseconds, not nanoseconds)"
        elif abs(after - lab.init_cpu_ns(c["pid"])) <= 20_000_000:
            hint = " (that is the CPU time of its first process, which only sleeps: the processes it started count too)"
        fail("the CPU time of %s grew by %s while its worker used %s%s" % (c["id"], ms(d), ms(used), hint))
    if d > used + OVER_MAX:
        fail("the CPU time of %s grew by %s while its worker used %s (the counter holds more than this container)" % (c["id"], ms(d), ms(used)))


def idle(name, before, after, who):
    d = after - before
    if d > IDLE_MAX:
        fail("the CPU time of %s grew by %s while only %s worked (the counter holds more than this container)" % (lab.load(work)["containers"][name]["id"], ms(d), who))


def total(name, value):
    c = lab.load(work)["containers"][name]
    if value < c["burned_ns"]:
        fail("usage_ns of %s is %s; its worker has used %s since the start (the total since the container started is meant)" % (c["id"], ms(value), ms(c["burned_ns"])))
    if value > c["burned_ns"] + TOTAL_OVER:
        fail("usage_ns of %s is %s; its worker has used %s since the start (the counter holds more than this container)" % (c["id"], ms(value), ms(c["burned_ns"])))


if not os.path.isfile(os.path.join(work, "cpu-usage.sh")):
    fail("there is no %s/cpu-usage.sh" % work)

if phase == "first":
    a0, _ = read("app")
    lab.burn(work, "job", 250)
    a1, _ = read("app")
    idle("app", a0, a1, CASE + "-job")
    u = lab.burn(work, "app", 300)
    b1, _ = read("app")
    grew("app", a1, b1, u)
    u = lab.burn(work, "app", 150)
    c1, _ = read("app")
    grew("app", b1, c1, u)
    total("app", c1)
    keep()
    print("  -> OK: %s of CPU time counted for %s (cgroup %s): it did not move while only the other container worked, and grew by what the worker used (300 ms, 150 ms)" % (
        ms(c1), CASE + "-app", lab.load(work)["containers"]["app"]["cgroup"]))
else:
    n0, c = read("more")
    u = lab.burn(work, "more", 300)
    n1, _ = read("more")
    grew("more", n0, n1, u)
    total("more", n1)
    a0, _ = read("app")
    lab.burn(work, "more", 120)
    a1, _ = read("app")
    idle("app", a0, a1, c["id"])
    keep()
    print("  -> OK: the container started after the script (%s, cgroup %s) is counted too (%s), and %s did not move while it worked" % (
        c["id"], c["cgroup"], ms(n1), CASE + "-app"))
