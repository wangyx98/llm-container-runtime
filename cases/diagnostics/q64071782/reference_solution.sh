#!/bin/bash
# Reference solution for q64071782: the CPU time of a runc container is a counter of its cgroup. The first process of the container (the PID that runc shows) is in that cgroup,
# so /proc/PID/cgroup tells where it is (whatever the cgroup version and the path: the path is chosen by whoever started the container); the cgroup directory below the mount of the
# hierarchy holds the counter of all the processes of the container together: cpuacct.usage (cgroup v1, nanoseconds) or usage_usec in cpu.stat (cgroup v2, microseconds).
set -e

W=/tmp/bench64071782
mkdir -p "$W"
cat > "$W/cpu-usage.sh" <<'SCRIPT'
#!/bin/bash
# cpu-usage.sh CONTAINER_ID OUTPUT_FILE
set -e
id=$1
out=$2
pid=$(sudo runc state "$id" | python3 -c 'import json, sys; print(json.load(sys.stdin)["pid"])')
python3 - "$pid" "$out" <<'PY'
import json
import sys

pid, out = sys.argv[1:3]
v1 = v2 = None
for line in open("/proc/self/mountinfo"):
    left, right = line.split(" - ", 1)
    fs, _, opts = right.split()[:3]
    if fs == "cgroup" and "cpuacct" in opts.split(",") and v1 is None:
        v1 = left.split()[4]
    if fs == "cgroup2" and v2 is None:
        v2 = left.split()[4]
for line in open("/proc/%s/cgroup" % pid):
    _, ctrl, path = line.rstrip("\n").split(":", 2)
    if v1 and "cpuacct" in ctrl.split(","):
        usage = int(open(v1 + path + "/cpuacct.usage").read())
        break
    if not v1 and ctrl == "":
        usage = next(int(l.split()[1]) for l in open(v2 + path + "/cpu.stat") if l.startswith("usage_usec ")) * 1000
        break
json.dump({"cgroup": path, "usage_ns": usage}, open(out, "w"))
PY
SCRIPT
chmod +x "$W/cpu-usage.sh"
bash "$W/cpu-usage.sh" bench64071782-app "$W/app-cpu.json"
cat "$W/app-cpu.json"
