#!/usr/bin/env python3
"""verify.py WORK : the postcondition of q72094271, run as root by oracle.sh. Prints one short FAIL line (the last line of the output) or "OK ...".

  1. the lab is as it was (lab.problems): the images, the file pattern of kernel.core_pattern, the probe program, and the containerd that answers is the main process of the service;
  2. phase A, the node as the solution left it: every pod is removed, then three NEW pods are made, each with a long-running container (main) and a container that aborts (crash):
       - the core limit of the main process (/proc/PID/limits), soft and hard, is 0;
       - an exec'd process (crictl exec) sees soft 0 and hard 0, and aborts with SIGABRT without leaving a core file (the file it wrote about itself says 0 0);
       - the container whose main process aborts exits with 134, saw 0 0 and left no core file;
  3. phase B, persistence: the evaluator restarts the service (plain `systemctl restart`, no daemon-reload and nothing else first), the lab must still be as it was, and two more new pods
     are judged the same way: a limit that was only put on the running process does not survive."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


def judge(o, phase):
    """the first thing that is wrong in one observation, or ''"""
    p = "[%s] " % phase
    s, h = o["main_limits"] or (None, None)
    if o["main_limits"] is None:
        return p + "the main process of a new container is gone before its limits could be read"
    if s != "0":
        return p + "the main process of a new container has core limit soft=%s hard=%s (it must be 0 and 0)" % (s, h)
    if h != "0":
        return p + "the HARD core limit of a new container is %s: a process can raise its soft limit again" % h
    if o["exec_limits"] is None:
        return p + "the exec probe gave no answer"
    if o["exec_limits"] != ("0", "0"):
        return p + "an exec'd process has core limit soft=%s hard=%s (it must be 0 and 0)" % o["exec_limits"]
    if o["exec_abort_limits"] != ["0", "0"]:
        return p + "the exec'd process that aborted saw core limits %s" % (o["exec_abort_limits"],)
    if o["exec_abort_cores"]:
        return p + "an exec'd process that aborted left a core file: %s" % o["exec_abort_cores"][0]
    if o["crash_exit"] != 134:
        return p + "the container whose main process aborts exited with %s, not 134 (SIGABRT)" % o["crash_exit"]
    if o["crash_limits"] != ["0", "0"]:
        return p + "the main process that aborted saw core limits %s" % (o["crash_limits"],)
    if o["crash_cores"]:
        return p + "a main process that aborted left a core file: %s" % o["crash_cores"][0]
    return ""


def phase(work, name, count):
    for i in range(1, count + 1):
        try:
            o = lab.observe(work, name.lower() + str(i))
        except lab.Fail as e:
            fail("[%s] %s" % (name, e))
        bad = judge(o, name)
        if bad:
            fail("pod %d: %s" % (i, bad))
        print("  pod %d: main %s/%s, exec %s/%s, aborts leave no core" % (i, o["main_limits"][0], o["main_limits"][1], o["exec_limits"][0], o["exec_limits"][1]))


def main(work):
    # the solution may have restarted the service a moment ago: judge the lab only when the node answers again
    if not lab.wait_ready():
        fail("containerd does not answer on %s (or lists no images of the lab) 60 seconds after the solution" % lab.SOCK)
    bad = lab.problems(work)
    if bad:
        fail(bad)
    lab.wipe_pods()
    print("phase A: the node as the solution left it (service pid %d)" % lab.service_pid())
    phase(work, "A", 3)
    before = lab.service_pid()
    r = lab.systemctl("restart", lab.UNIT, timeout=180)
    if r.returncode != 0:
        fail("systemctl restart %s failed: %s" % (lab.UNIT, lab.short(r.stderr)))
    if not lab.wait_ready(90):
        fail("containerd does not answer after the restart")
    time.sleep(1)
    after = lab.service_pid()
    if not after or after == before:
        fail("the service was not restarted (pid %s -> %s)" % (before, after))
    bad = lab.problems(work)
    if bad:
        fail("after the restart: " + bad)
    lab.wipe_pods()
    print("phase B: after systemctl restart (service pid %d -> %d)" % (before, after))
    phase(work, "B", 2)
    print("OK: new containers, their exec'd processes and the processes that abort have core limit 0/0 and leave no core file, as left by the solution and after a restart of the service")


if __name__ == "__main__":
    main(sys.argv[1])
