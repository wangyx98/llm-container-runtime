#!/bin/bash
# Postcondition oracle. The node must be as the lab made it except for the gVisor release and the two gVisor pods, and the gVisor pods must report their own CPU:
#  1. the lab's files are unchanged (the pods' definitions, containerd's and runsc's configuration, the shim, every release of runsc in the node's disk, the tools); the shim link is where it was;
#     the runsc that the node finds is a file of one of the releases of the lab (no wrapper, no other binary);
#  2. the node has exactly the three pods gv-busy, gv-idle, rc-busy, each Ready with one running container of the lab's image (busy / idle program as before); gv-* have the handler runsc,
#     rc-busy is the control: the same pod and container as at setup, handler runc;
#  3. the sandbox of each gVisor pod runs a binary of a release of the lab (the pods were run again under the new runsc);
#  4. over 6 seconds, at both layers (CRI: crictl stats, containerd: ctr tasks metrics): gv-busy grows like the control (about one core, at least 0.45 of the control, at most 1.6) and its counter since its start is possible for that age; gv-idle grows
#     almost nothing; the two layers agree; gv-busy and rc-busy both report a working set; rc-busy grows at about one core. A counter that is 0, or that is not the pod's own (a number
#     that is too big for the pod's age, or the same growth for the idle pod), does not pass.

CASE_ID="bench63132692"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/containerd.sock"
NODEBIN="$LIB/node/bin"
fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab's files, the shim and the runsc that the node finds..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed (the pods' definitions, the configuration, the shim, a release of runsc or a tool)"
[ "$(sudo readlink "$NODEBIN/containerd-shim-runsc-v1")" = "$(sudo cat "$STATE_DIR/shim.link")" ] || fail "the shim link was changed"
sudo crictl -r "unix://$SOCK" -i "unix://$SOCK" version >/dev/null 2>&1 || fail "the node's containerd does not answer on $SOCK"

sudo python3 - "$LIB" "$SOCK" "$STATE_DIR" <<'PYEOF' || exit 1
import hashlib
import json
import os
import re
import subprocess
import sys
import time

L, SOCK, STATE = sys.argv[1:4]
BOX_REF = "bench63132692.local/box:1"


def bad(msg):
    print("[oracle] FAIL: " + msg)
    sys.exit(1)


def run(*a):
    return subprocess.run(list(a), capture_output=True, text=True)


def cr(*a):
    r = run("crictl", "-r", "unix://" + SOCK, "-i", "unix://" + SOCK, a[0], "-o", "json", *a[1:])
    try:
        return json.loads(r.stdout)
    except ValueError:
        bad("crictl %s did not answer: %s" % (" ".join(a), r.stderr.strip()[-200:]))


def ctr_cpu(cid):
    for line in run("ctr", "-a", SOCK, "-n", "k8s.io", "tasks", "metrics", cid).stdout.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] == "cpuacct.usage":
            return int(f[1])
        if len(f) >= 2 and f[0] == "cpu.usage_usec":
            return int(f[1]) * 1000
    return None


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


# the releases of the lab (the record of setup): sha256 -> release
releases = {}
for line in open(os.path.join(STATE, "lab.sha")):
    h, p = line.split(None, 1)
    m = re.search(r"/releases/([^/]+)/runsc$", p.strip())
    if m:
        releases[h] = m.group(1)
node_runsc = os.path.join(L, "node/bin/runsc")
try:
    node_hash = sha256_of(node_runsc)
except OSError:
    bad("the node has no runsc (node/bin/runsc)")
if node_hash not in releases:
    bad("the runsc that the node finds is not a file of one of the lab's releases (no wrapper or other binary)")
print("[oracle] the node runs the gVisor release %s" % releases[node_hash])

# the pods and containers
pods_all = cr("pods")["items"]
names = sorted(p["metadata"]["name"] for p in pods_all)
if names != ["gv-busy", "gv-idle", "rc-busy"]:
    bad("the node must have exactly the pods gv-busy, gv-idle and rc-busy, it has: %s" % ", ".join(names))
pods = {p["metadata"]["name"]: p for p in pods_all}
for n, p in pods.items():
    if p["state"] != "SANDBOX_READY":
        bad("the pod %s is not Ready" % n)
want_handler = {"gv-busy": "runsc", "gv-idle": "runsc", "rc-busy": "runc"}
want_prog = {"gv-busy": "spin", "gv-idle": "idle", "rc-busy": "spin"}
for n, h in want_handler.items():
    if pods[n].get("runtimeHandler", "") != h:
        bad("the pod %s has the runtime handler %r, it must keep %r" % (n, pods[n].get("runtimeHandler", ""), h))
ctrs_all = cr("ps", "-a")["containers"]
ctrs = {}
for c in ctrs_all:
    n = next((k for k, p in pods.items() if p["id"] == c["podSandboxId"]), None)
    if n is None:
        bad("a container (%s) belongs to no pod of the lab" % c["id"][:12])
    if n in ctrs:
        bad("the pod %s has more than one container" % n)
    ctrs[n] = c
for n in want_handler:
    c = ctrs.get(n)
    if not c or c["state"] != "CONTAINER_RUNNING":
        bad("the pod %s has no running container" % n)
    if BOX_REF not in (c["image"].get("image"), c["image"].get("userSpecifiedImage"), c.get("imageRef")) and BOX_REF not in json.dumps(c["image"]):
        bad("the container of %s does not use the lab's image" % n)
    spec = cr("inspect", c["id"])
    args = spec.get("info", {}).get("runtimeSpec", {}).get("process", {}).get("args", [])
    if not args or os.path.basename(args[0]) != want_prog[n]:
        bad("the container of %s does not run /bin/%s (%s)" % (n, want_prog[n], args))
recorded = {l.split()[0]: l.split() for l in open(os.path.join(STATE, "pods.txt")) if l.strip()}
if (pods["rc-busy"]["id"], ctrs["rc-busy"]["id"]) != (recorded["rc-busy"][1], recorded["rc-busy"][2]):
    bad("the control pod rc-busy is not the one that setup made (it must not be touched)")
print("[oracle] the pods: gv-busy and gv-idle (runsc), rc-busy (runc, unchanged), each with one running container")

# the sandbox processes of the gVisor pods run a release of the lab
for n in ("gv-busy", "gv-idle"):
    sid = pods[n]["id"]
    found = None
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            cmd = open("/proc/%s/cmdline" % d, "rb").read().split(b"\0")
        except OSError:
            continue
        if cmd and cmd[0] == b"runsc-sandbox" and sid.encode() in b" ".join(cmd):
            found = d
            break
    if not found:
        bad("no gVisor sandbox process (runsc-sandbox) runs the pod %s: it does not run in gVisor" % n)
    try:
        h = sha256_of("/proc/%s/exe" % found)
    except OSError:
        bad("cannot read the binary of the sandbox of %s" % n)
    if h not in releases:
        bad("the sandbox of %s does not run a binary of the lab's releases" % n)
    print("[oracle] the sandbox of %s runs the gVisor release %s" % (n, releases[h]))


def snapshot():
    t = time.monotonic()
    stats = {s["attributes"]["id"]: s for s in cr("stats")["stats"]}
    out = {}
    for n in want_handler:
        cid = ctrs[n]["id"]
        s = stats.get(cid, {})
        out[n] = dict(cri=int(s.get("cpu", {}).get("usageCoreNanoSeconds", {}).get("value", 0)),
                      ws=int(s.get("memory", {}).get("workingSetBytes", {}).get("value", 0)), ctr=ctr_cpu(cid), t=(t + time.monotonic()) / 2)
    return out


now = time.time()
age = {n: now - int(ctrs[n]["createdAt"]) / 1e9 for n in want_handler}
a = snapshot()
time.sleep(6)
b = snapshot()
dt = b["rc-busy"]["t"] - a["rc-busy"]["t"]
rate = {n: {k: ((b[n][k] - a[n][k]) / 1e9 / dt if a[n][k] is not None and b[n][k] is not None else None) for k in ("cri", "ctr")} for n in want_handler}
for n in want_handler:
    print("[oracle] %-8s CRI %s core/s (counter %.1f s, container age %.0f s), containerd %s core/s, working set %d bytes" % (
        n, "%.2f" % rate[n]["cri"], a[n]["cri"] / 1e9, age[n], "%.2f" % rate[n]["ctr"] if rate[n]["ctr"] is not None else "none", b[n]["ws"]))
if rate["rc-busy"]["cri"] < 0.4:
    bad("the control pod rc-busy does not report its CPU")
for layer in ("cri", "ctr"):
    r = rate["gv-busy"][layer]
    name = "CRI" if layer == "cri" else "containerd"
    if r is None:
        bad("the %s layer reports no CPU for gv-busy" % name)
    if r == 0 and a["gv-busy"][layer] == 0:
        bad("gv-busy reports a CPU counter of 0 at the %s layer: the CPU of the gVisor pod is not reported" % name)
    low = max(0.2, 0.45 * rate["rc-busy"]["cri"])       # a pod that uses one CPU grows like the control pod, which runs the same loop, up to the share of the CPU that it gets
    if not low <= r <= 1.6:
        bad("gv-busy grows at %.2f core/s at the %s layer; a pod that uses one CPU grows like the control (%.2f), at most at 1.6 (not the pod's own CPU)" % (r, name, rate["rc-busy"]["cri"]))
    if a["gv-busy"][layer] / 1e9 > 1.6 * age["gv-busy"] + 1:
        bad("the counter of gv-busy at the %s layer (%.1f s) is more than the pod can have used in %.0f s: it is not the pod's own CPU" % (name, a["gv-busy"][layer] / 1e9, age["gv-busy"]))
    ri = rate["gv-idle"][layer]
    if ri is None or ri > 0.25:
        bad("gv-idle (sleeping) grows at %s core/s at the %s layer: the number is not the pod's own CPU" % (ri, name))
    if r < 4 * max(ri, 0.02):
        bad("gv-busy and gv-idle cannot be told apart at the %s layer" % name)
    if a["gv-idle"][layer] / 1e9 > 0.25 * age["gv-idle"] + 1:
        bad("the counter of gv-idle at the %s layer (%.1f s) is too big for a sleeping pod" % (name, a["gv-idle"][layer] / 1e9))
if abs(rate["gv-busy"]["cri"] - rate["gv-busy"]["ctr"]) > 0.3 * max(rate["gv-busy"]["cri"], rate["gv-busy"]["ctr"]):
    bad("the two layers disagree about gv-busy (CRI %.2f, containerd %.2f)" % (rate["gv-busy"]["cri"], rate["gv-busy"]["ctr"]))
if b["gv-busy"]["ws"] <= 0:
    bad("gv-busy reports no memory")
print("[oracle] OK: gv-busy reports about one core and gv-idle almost none, at both layers; the pods are still in gVisor; the runc control is untouched.")
PYEOF
