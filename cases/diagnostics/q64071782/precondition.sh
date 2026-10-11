#!/bin/bash
set -e

CASE_ID="bench64071782"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them, and runc lists the two containers as running..."
(cd "$STATE_DIR" && sha256sum app.c lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper of the lab was changed"
for n in job app; do
    sudo runc state "$CASE_ID-$n" 2>/dev/null | grep -q '"status": "running"' || fail "the container $CASE_ID-$n is not running"
done
python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK: $(sudo runc list 2>/dev/null | grep -c "$CASE_ID-") containers of the case in 'runc list'; runc $(runc --version | head -1 | awk '{print $3}')"

echo "[precondition] in each container the first process sleeps and its child works, both in the container's cgroup; the two cgroups are different, below one random parent..."
python3 - "$STATE_DIR" <<'PYEOF' || fail "the lab's record is not what the case is built on"
import json
import os
import re
import sys

sys.path.insert(0, sys.argv[1])
import lab

t = json.load(open(os.path.join(sys.argv[1], "truth.json")))["containers"]
assert sorted(t) == ["app", "job"], "two containers"
for name, c in t.items():
    st, ppid, _, _ = lab.read_stat(c["pid"])
    assert st == "S", "the first process of %s sleeps (state %s)" % (name, st)
    assert open("/proc/%d/cmdline" % c["pid"]).read() == "/app\0init\0", "the first process runs /app init"
    assert lab.read_stat(c["worker"])[1] == c["pid"], "the worker of %s is a child of the first process" % name
    assert lab.cgroup_of(c["worker"]) == c["cgroup"] == lab.cgroup_of(c["pid"]), "both processes of %s are in one cgroup" % name
    assert os.path.isdir(lab.hierarchy()[1] + c["cgroup"]), "the cgroup directory of %s exists" % name
a, j = t["app"]["cgroup"], t["job"]["cgroup"]
assert a != j and os.path.dirname(a) == os.path.dirname(j), "two cgroups below one parent"
assert re.fullmatch(r"/bench64071782-[0-9a-f]{8}", os.path.dirname(a)), "a random parent"
assert os.path.basename(a) == "bench64071782-app", "the cgroup is named after the container"
PYEOF
KIND=$(python3 -c "import sys; sys.path.insert(0, '$STATE_DIR'); import lab; k, m = lab.hierarchy(); print('cgroup v1 (cpuacct, mounted at %s)' % m if k == 'v1' else 'cgroup v2 (cpu.stat, mounted at %s)' % m)")
echo "  -> OK: the first process of each container is 'app init' in state S, its child 'app burn' works for it; both cgroups are below /$CASE_ID-<random>; this host has $KIND"

echo "[precondition] the problem: when the worker uses 200 ms of CPU time, the CPU time of the first process (/proc/PID/stat) does not move, the counter of the cgroup does..."
python3 - "$STATE_DIR" "$WORK_DIR" <<'PYEOF' || fail "the CPU time of the worker is not in the cgroup of the container only"
import json
import os
import sys
import time

sys.path.insert(0, sys.argv[1])
import lab

work = sys.argv[2]
c = json.load(open(os.path.join(sys.argv[1], "truth.json")))["containers"]["app"]
j = json.load(open(os.path.join(sys.argv[1], "truth.json")))["containers"]["job"]
init0 = lab.read_stat(c["pid"])[2]
a0, j0 = lab.counter(c["cgroup"]), lab.counter(j["cgroup"])
used = lab.burn(work, "app", 200)
time.sleep(0.3)
a1, j1 = lab.counter(c["cgroup"]), lab.counter(j["cgroup"])
init1 = lab.read_stat(c["pid"])[2]
assert abs(used - 200_000_000) < 5_000_000, "the worker used %d ns for 200 ms" % used
assert init1 == init0, "the first process used no CPU time (%d ticks before, %d after)" % (init0, init1)
assert used - 1_000_000 <= a1 - a0 <= used + 30_000_000, "the counter of the cgroup grew by %d ns, the worker used %d" % (a1 - a0, used)
assert j1 - j0 < 30_000_000, "the counter of the other container did not move (%d ns)" % (j1 - j0)
print("  -> OK: the worker used %.1f ms; the counter of the cgroup grew by %.1f ms; the first process %d ticks before and after; the other container's counter by %.1f ms" % (
    used / 1e6, (a1 - a0) / 1e6, init0, (j1 - j0) / 1e6))
PYEOF

echo "[precondition] nothing to read it by: no script, and the path of the answer on the question (the hierarchy's user.slice) does not exist..."
[ ! -e "$WORK_DIR/cpu-usage.sh" ] || fail "$WORK_DIR/cpu-usage.sh exists already"
[ ! -e "/sys/fs/cgroup/cpu,cpuacct/user.slice/$CASE_ID-app" ] || fail "the path of the answer exists"
echo "  -> OK"

echo "[precondition] ALL CHECKS PASSED: two runc containers with a sleeping first process and a working child, in cgroups with random paths, the CPU time is in the cgroup and not in the first process, and there is no cpu-usage.sh."
