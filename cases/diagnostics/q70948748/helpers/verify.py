"""verify.py WORK SET : ask the solution's script for the owner of a series of host PIDs and compare with the lab's record.

SET is first (every container of setup: its first process, its grandchild and its orphan; the decoy process of the node) or second (after the node
changed: the new containers' first process, child, grandchild and orphan; one process, chosen at random, of each older container; the decoy again).
For each PID it runs `bash WORK/pid-owner.sh PID WORK/out-owner.json` and checks, in this order: the exit status, that the file is JSON, that a
process of the node has the owner null (and a process of a container does not), container_id (the full ID of the container the process is in),
pod_uid, pod_namespace, pod_name, container_name and init_pid (the host PID of the first process of that container). Prints one short line for the
first thing that is wrong (variable-length details last) and exits 1; prints one line and exits 0 when all is right."""
import json
import os
import random
import re
import subprocess
import sys

work, which = sys.argv[1:3]
truth = json.load(open(os.path.join(work, ".bench", "truth.json")))
out = os.path.join(work, "out-owner.json")
R = random.SystemRandom()


def pod_of(c):
    return truth["pods"][c["sandbox"]]


def label(c):
    return "%s of %s/%s" % (c["name"], pod_of(c)["ns"], pod_of(c)["name"])


queries = []
for cid, c in truth["containers"].items():
    if which == "first":
        kinds = ["init", "grandchild", "orphan"]
    elif c["gen"] == 2:
        kinds = ["init", "child", "grandchild", "orphan"]
    else:
        kinds = [R.choice(["init", "child", "grandchild", "orphan"])]
    for k in kinds:
        queries.append(("the %s process of the container %s" % ("first" if k == "init" else k, label(c)), c["procs"][k], cid))
R.shuffle(queries)
queries.append(("a process of the node (it is not in a container)", truth["host"]["pid"], None))


def fail(what, pid, msg):
    print("  -> FAIL: %s (pid %d): %s" % (what, pid, msg))
    sys.exit(1)


for what, pid, cid in queries:
    if os.path.exists(out):
        os.unlink(out)
    try:
        r = subprocess.run(["bash", os.path.join(work, "pid-owner.sh"), str(pid), out], cwd=work, capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        fail(what, pid, "the script did not finish in 90 s")
    if r.returncode != 0:
        fail(what, pid, "the script exits with status %d: %s" % (r.returncode, (r.stderr.strip() or r.stdout.strip())[-160:]))
    if not os.path.isfile(out):
        fail(what, pid, "the script wrote no output file")
    try:
        got = json.load(open(out))
    except ValueError as e:
        fail(what, pid, "the output is not JSON (%s)" % str(e)[:60])
    if cid is None:
        if got is not None:
            fail(what, pid, "the script reports an owner (%s) for a process that is in no container; it must write null" % (
                got.get("container_id", "?")[:12] if isinstance(got, dict) else got))
        continue
    c = truth["containers"][cid]
    if got is None:
        fail(what, pid, "no owner reported (null), the process is in this container")
    if not isinstance(got, dict):
        fail(what, pid, "the output is not a JSON object")
    gid = str(got.get("container_id", ""))
    if not re.fullmatch(r"[0-9a-f]{64}", gid):
        fail(what, pid, "container_id is not a full 64-character ID: %s" % gid[:20])
    if gid != cid:
        other = truth["containers"].get(gid)
        fail(what, pid, "container_id is that of %s, the process is in %s" % (label(other) if other else gid[:12], label(c)))
    p = pod_of(c)
    for key, want in (("pod_uid", p["uid"]), ("pod_namespace", p["ns"]), ("pod_name", p["name"]), ("container_name", c["name"]), ("init_pid", c["procs"]["init"])):
        v = got.get(key)
        if isinstance(v, str) and key == "init_pid" and v.isdigit():
            v = int(v)
        if v != want:
            fail(what, pid, "%s is %s, it should be %s" % (key, v, want))
print("  -> OK: %s: %d processes (of containers and of the node) each with the right owner" % (which, len(queries)))
