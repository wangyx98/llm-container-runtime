#!/bin/bash
set -e

CASE_ID="bench76608572"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them, and the lab's rootfs has the workload..."
(cd "$STATE_DIR" && sha256sum idle.c lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
sudo test -x /var/lib/$CASE_ID/rootfs/idle || fail "the lab's workload is missing"
[ -z "$(sudo runc list -q 2>/dev/null | grep "^$CASE_ID-")" ] || fail "a container of the case is already running"
[ ! -e "$WORK_DIR/cpu-report.sh" ] || fail "the solution's script exists before the solution ran"

echo "[precondition] control: two real containers with the SAME cpuset constraint, one in a private cgroup namespace and one in the host's (a privileged-style container); what each of them sees..."
OUT=$(sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR") || { echo "$OUT" | tail -3 | cut -c1-300; fail "see above"; }
python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print("  constraint (runc linux.resources.cpu.cpus): %s; the host root cgroup has %s" % (d["constraint"], d["host_root_effective"]))
for k in ("private", "host"):
    x = d[k]
    print("  %-7s cgroup ns inode %s (host %s); host /proc/PID/cgroup: %s" % (k, x["cgroupns"].split("[")[-1].rstrip("]"), x["host_cgroupns"].split("[")[-1].rstrip("]"), x["proc_cgroup_line"][3:]))
    print("          mountinfo root of its /sys/fs/cgroup: %s; cpuset.cpus.effective of its cgroup: %s; Cpus_allowed_list: %s" % (x["view_mount_root"], x["cgroup_dir_effective"], x["cpus_allowed_list"]))
    print("          cpuset.cpus at the root of its /sys/fs/cgroup: %s; cpuset files there: %s" % (x["cpuset_cpus_in_view"] if x["cpuset_cpus_in_view"] is not None else "No such file or directory", " ".join(x["view_entries_cpuset"])))
' <<< "$(echo "$OUT" | sed '/^  -> /d')"
echo "[precondition] PASS - the same real CPU constraint; cpuset.cpus is at the root of the private container's view and missing in the host-namespace container's."
