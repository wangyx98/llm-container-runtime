#!/bin/bash
# Why cpuset.cpus is missing: on cgroup v2 a container in a PRIVATE cgroup namespace sees its own cgroup as the root of /sys/fs/cgroup (so cpuset.cpus is right there), while a
# container that shares the HOST's cgroup namespace (a privileged pod) sees the host's root cgroup, which has no cpuset.cpus (the root cgroup has no interface files of the
# controllers, only cpuset.cpus.effective, the CPUs of the whole machine). The container's own cgroup is a directory below that root, named by the `0::` line of /proc/PID/cgroup
# (seen from the host the path is complete); its cpuset.cpus.effective is the real allocation. The script finds it from the host, for a PID or a runc container ID.
set -e
cat > /tmp/bench76608572/cpu-report.sh <<'SCRIPT'
#!/bin/bash
# cpu-report.sh TARGET OUTPUT_FILE   (TARGET: host PID of a process of the container, or its runc container ID)
python3 - "$1" "$2" <<'PY'
import json
import os
import re
import subprocess
import sys

target, out = sys.argv[1:3]
CG = "/sys/fs/cgroup"


def sudo(*cmd):
    return subprocess.run(["sudo", *cmd], capture_output=True, text=True, check=True).stdout


pid = int(target) if target.isdigit() else json.loads(sudo("runc", "state", target))["pid"]
line = next(l for l in open("/proc/%d/cgroup" % pid).read().splitlines() if l.startswith("0::"))
cgroup_dir = (CG + line[3:]).rstrip("/") or CG
effective = open(cgroup_dir + "/cpuset.cpus.effective").read().strip()
view_root = None
for l in sudo("cat", "/proc/%d/mountinfo" % pid).splitlines():
    f = l.split()
    if len(f) > 9 and f[4] == CG and f[f.index("-") + 1] == "cgroup2":
        view_root = f[3]
view_root_dir = (CG + view_root).rstrip("/") if view_root and view_root != "/" else CG
has_cpus = subprocess.run(["sudo", "test", "-e", "/proc/%d/root%s/cpuset.cpus" % (pid, CG)]).returncode == 0
json.dump({"cgroup_dir": cgroup_dir, "effective_cpus": effective, "view_root_dir": view_root_dir,
           "view_shows_own_cgroup": view_root_dir == cgroup_dir, "cpuset_cpus_in_view": has_cpus}, open(out, "w"), indent=1)
PY
SCRIPT
chmod +x /tmp/bench76608572/cpu-report.sh
echo "[solution] /tmp/bench76608572/cpu-report.sh written; usage: bash /tmp/bench76608572/cpu-report.sh PID_OR_CONTAINER_ID OUTPUT_FILE"
