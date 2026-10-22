#!/bin/bash
# Precondition oracle: the lab is as setup.sh made it, and the problem is there:
#  - the lab's files are unchanged, the node answers, the three pods are Ready with the runtime handlers they were made with (gv-busy, gv-idle: runsc; rc-busy: runc);
#  - the node's runsc is the old release 20210125.0;
#  - the busy runc pod (the control) reports a CPU counter that grows at about one core, at both layers (CRI: crictl stats; containerd: ctr tasks metrics), while the two gVisor pods
#    report 0 at both layers and a working set > 0 (memory is reported, CPU is not);
#  - the lab can be solved: with a newer runsc (20260105.0, switched in node/bin for this check only) a fresh gVisor pod running the same busy program reports a growing CPU counter (it shares the CPUs with two other busy loops, so a share of a core).

CASE_ID="bench63132692"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/containerd.sock"
NODEBIN="$LIB/node/bin"
fail() { echo "[precondition] FAIL: $*"; exit 1; }
restore() { sudo ln -sfn "$(sudo cat "$STATE_DIR/runsc.link")" "$NODEBIN/runsc" 2>/dev/null; }

echo "[precondition] the lab's files are as setup left them..."
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha'" >/dev/null 2>&1 || fail "a file of the lab was changed"
[ "$(sudo readlink "$NODEBIN/runsc")" = "$(sudo cat "$STATE_DIR/runsc.link")" ] || fail "node/bin/runsc does not point where setup put it"
sudo readlink "$NODEBIN/runsc" | grep -q "/releases/20210125.0/runsc$" || fail "the node does not run the release 20210125.0"
[ "$(sudo readlink "$NODEBIN/containerd-shim-runsc-v1")" = "$(sudo cat "$STATE_DIR/shim.link")" ] || fail "the shim link was changed"
sudo crictl -r "unix://$SOCK" -i "unix://$SOCK" version >/dev/null 2>&1 || fail "the node's containerd does not answer on $SOCK"

echo "[precondition] the pods, their handlers, and the CPU counters of the busy runc pod and of the two gVisor pods..."
sudo python3 - "$LIB" "$SOCK" "$STATE_DIR" <<'PYEOF' || exit 1
import json
import subprocess
import sys
import time

L, SOCK, STATE = sys.argv[1:4]


def run(*a):
    return subprocess.run(list(a), capture_output=True, text=True)


def cr(*a):
    r = run("crictl", "-r", "unix://" + SOCK, "-i", "unix://" + SOCK, a[0], "-o", "json", *a[1:])
    return json.loads(r.stdout)


def ctr_cpu(cid):
    for line in run("ctr", "-a", SOCK, "-n", "k8s.io", "tasks", "metrics", cid).stdout.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] == "cpuacct.usage":
            return int(f[1])
        if len(f) >= 2 and f[0] == "cpu.usage_usec":
            return int(f[1]) * 1000
    return None


def snapshot():
    """name -> (pod id, handler, container id, CRI cpu ns, CRI working set, ctr cpu ns) of the running containers of the Ready pods"""
    t = time.monotonic()
    pods = {p["id"]: p for p in cr("pods")["items"] if p["state"] == "SANDBOX_READY"}
    stats = {s["attributes"]["id"]: s for s in cr("stats")["stats"]}
    out = {}
    for c in cr("ps")["containers"]:
        p = pods.get(c["podSandboxId"])
        if not p or c["state"] != "CONTAINER_RUNNING":
            continue
        s = stats.get(c["id"], {})
        out[p["metadata"]["name"]] = dict(pod=p["id"], handler=p.get("runtimeHandler", ""), cid=c["id"],
                                          cri=int(s.get("cpu", {}).get("usageCoreNanoSeconds", {}).get("value", 0)),
                                          ws=int(s.get("memory", {}).get("workingSetBytes", {}).get("value", 0)), ctr=ctr_cpu(c["id"]),
                                          t=(t + time.monotonic()) / 2)
    return out


def bad(msg):
    print("[precondition] FAIL: " + msg)
    sys.exit(1)


a = snapshot()
for n, h in (("gv-busy", "runsc"), ("gv-idle", "runsc"), ("rc-busy", "runc")):
    if n not in a:
        bad("the pod %s is not Ready with a running container" % n)
    if a[n]["handler"] != h:
        bad("the pod %s has the runtime handler %r, not %r" % (n, a[n]["handler"], h))
time.sleep(6)
b = snapshot()
dt = b["rc-busy"]["t"] - a["rc-busy"]["t"]
rate = lambda n, k: (b[n][k] - a[n][k]) / 1e9 / dt
print("[precondition] rc-busy (runc): CRI %.2f core/s, containerd %.2f core/s" % (rate("rc-busy", "cri"), rate("rc-busy", "ctr")))
if rate("rc-busy", "cri") < 0.4 or rate("rc-busy", "ctr") < 0.4:
    bad("the busy runc pod does not report a growing CPU counter (the machine has no free CPU?)")
for n in ("gv-busy", "gv-idle"):
    print("[precondition] %s (runsc 20210125.0): CRI cpu %d, containerd cpu %s, working set %d bytes" % (n, b[n]["cri"], b[n]["ctr"], b[n]["ws"]))
    if a[n]["cri"] != 0 or b[n]["cri"] != 0 or a[n]["ctr"] not in (0, None) or b[n]["ctr"] not in (0, None):
        bad("the gVisor pod %s reports a CPU counter: the problem is not there" % n)
    if b[n]["ws"] <= 0:
        bad("the gVisor pod %s reports no memory either" % n)
PYEOF

echo "[precondition] the lab can be solved: a fresh gVisor pod under the release 20260105.0 reports a CPU counter that grows (node/bin/runsc is switched for this check and restored)..."
trap restore EXIT
sudo tee "$STATE_DIR/probe.pod.json" >/dev/null <<PEOF
{
  "metadata": {"name": "probe", "namespace": "lab", "uid": "probe-uid", "attempt": 1},
  "log_directory": "$RUN/log/probe",
  "linux": {"cgroup_parent": "/$CASE_ID", "security_context": {"namespace_options": {"network": 2}}}
}
PEOF
sudo sh -c "sed 's/gv-busy/probe/' '$LIB/pods/gv-busy.ctr.json' > '$STATE_DIR/probe.ctr.json'"
sudo ln -sfn "$LIB/releases/20260105.0/runsc" "$NODEBIN/runsc"
CR="sudo crictl -r unix://$SOCK -i unix://$SOCK"
PP=$($CR runp --runtime runsc "$STATE_DIR/probe.pod.json" 2>/dev/null) || fail "a gVisor pod could not be run with the release 20260105.0"
PC=$($CR create "$PP" "$STATE_DIR/probe.ctr.json" "$STATE_DIR/probe.pod.json" 2>/dev/null) && $CR start "$PC" >/dev/null 2>&1 || { $CR stopp "$PP" >/dev/null 2>&1; $CR rmp -f "$PP" >/dev/null 2>&1; fail "the probe container could not be started"; }
sleep 2
V0=$($CR stats -o json 2>/dev/null | python3 -c "import json,sys; print([int(s['cpu']['usageCoreNanoSeconds']['value']) for s in json.load(sys.stdin)['stats'] if s['attributes']['id']=='$PC'][0])")
sleep 5
V1=$($CR stats -o json 2>/dev/null | python3 -c "import json,sys; print([int(s['cpu']['usageCoreNanoSeconds']['value']) for s in json.load(sys.stdin)['stats'] if s['attributes']['id']=='$PC'][0])")
$CR stopp "$PP" >/dev/null 2>&1; $CR rmp "$PP" >/dev/null 2>&1
restore
trap - EXIT
python3 -c "import sys; d=(int('$V1')-int('$V0'))/1e9/5; print('[precondition] probe pod under 20260105.0: %.2f core/s' % d); sys.exit(0 if 0.25 <= d <= 1.6 else 1)" || fail "a newer runsc does not report the CPU of a busy gVisor pod on this machine"
[ "$(sudo readlink "$NODEBIN/runsc")" = "$(sudo cat "$STATE_DIR/runsc.link")" ] || fail "node/bin/runsc was not restored"
sudo crictl -r "unix://$SOCK" -i "unix://$SOCK" pods --name probe -q | grep -q . && fail "the probe pod is still there"

echo "[precondition] OK: runc reports its CPU, gVisor (20210125.0) reports memory and no CPU, and a newer runsc fixes it."
