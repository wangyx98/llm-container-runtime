#!/bin/bash
# Reference solution: the orphan G is not a child of its creator P any more because P exited; the kernel hands an orphan to the nearest ancestor that is a subreaper (PR_SET_CHILD_SUBREAPER), and if
# there is none, to the init of the orphan's PID namespace. containerd's shim is a subreaper. In a container with its OWN pid namespace the container's init (the main process M) is the init of that
# namespace and adopts G: G is a child of M (the thread's own experiment). With hostPID there is no namespace of its own: M is no init, the nearest subreaper above G is the shim, G becomes a child of the
# shim, a sibling of M (Weave's kube-utils). `privileged` has nothing to do with it. proctree reports this from /proc, container by container, reading only.
set -e
LIB="/var/lib/bench63115522"
sudo tee "$LIB/proctree" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import re
import subprocess

LIB = "/var/lib/bench63115522"


def cr(*args):
    return subprocess.run([LIB + "/bin/crictl"] + list(args), check=True, capture_output=True, text=True).stdout


procs = {}
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    try:
        pid = int(name)
        stat = open("/proc/%d/stat" % pid).read()
        rest = stat[stat.rindex(")") + 2:].split()
        status = open("/proc/%d/status" % pid).read()
        procs[pid] = {
            "comm": stat[stat.index("(") + 1:stat.rindex(")")],
            "ppid": int(rest[1]),
            "starttime": int(rest[19]),
            "cmdline": open("/proc/%d/cmdline" % pid, "rb").read().decode(errors="replace").split("\0")[:-1],
            "nspid": [int(x) for x in re.search(r"^NSpid:\s*(.*)$", status, re.M).group(1).split()],
            "cgroup": open("/proc/%d/cgroup" % pid).read(),
            "pidns": os.readlink("/proc/%d/ns/pid" % pid),
        }
    except (OSError, ValueError, AttributeError):
        continue

pods = {p["id"]: p["metadata"]["name"] for p in json.loads(cr("pods", "-o", "json"))["items"]}
out = {}
for c in json.loads(cr("ps", "-o", "json"))["containers"]:
    m = re.search(r"parent=(\d+) child=(\d+) token=(\S+)", cr("logs", c["id"]))
    if not m:
        continue
    parent, token = int(m.group(1)), m.group(3)
    orphan = next(p for p, v in procs.items() if v["cmdline"] == ["orph", "grandchild", token])
    o = procs[orphan]
    main = json.loads(cr("inspect", c["id"]))["info"]["pid"]
    a = o["ppid"]
    if procs[a]["comm"] == "containerd-shim":
        kind = "shim"
    elif a == 1:
        kind = "host_init"
    elif len(procs[a]["nspid"]) > 1 and procs[a]["nspid"][-1] == 1:
        kind = "container_init"
    else:
        kind = "other"
    shim = None
    x = a
    while x > 1:
        if procs[x]["comm"] == "containerd-shim":
            cmd = procs[x]["cmdline"]
            shim = {"pid": x, "id": cmd[cmd.index("-id") + 1], "owns_container": x == procs[main]["ppid"]}
            break
        x = procs[x]["ppid"]
    gone = not any(v["cgroup"] == o["cgroup"] and v["nspid"][-1] == parent for v in procs.values())
    out[c["id"]] = {
        "pod": pods[c["podSandboxId"]], "container": c["metadata"]["name"], "token": token,
        "orphan": {"pid": orphan, "ppid": a, "starttime": o["starttime"], "nspid": o["nspid"],
                   "pid_ns": "host" if o["pidns"] == os.readlink("/proc/self/ns/pid") else "private"},
        "original_parent": {"pid": parent, "exited": gone},
        "adopter": {"pid": a, "comm": procs[a]["comm"], "kind": kind},
        "shim": shim,
    }
print(json.dumps({"containers": out}, indent=1, sort_keys=True))
PYEOF
sudo chmod 755 "$LIB/proctree"
sudo "$LIB/proctree"
