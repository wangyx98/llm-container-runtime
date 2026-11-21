#!/bin/bash
set -e

CASE_ID="bench68684356"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"
GATE="$LIB_BASE/gate"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
fail() { echo "  -> FAIL: $*"; exit 1; }
KRO=$(sj kro)

echo "[precondition] checking the state setup recorded, the node's processes, and that the machine has no API server..."
sudo test -s "$STATE_DIR/state.json" || fail "setup did not record its state"
"$WORK_DIR/bin/node-ctl" status >/dev/null 2>&1 || fail "node-ctl says the node (containerd and kubelet) is not running"
[ ! -e "$WORK_DIR/bin/pod-ready" ] || fail "$WORK_DIR/bin/pod-ready exists before the solution"
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.](6443|8080)$'; then fail "something listens on 6443 or 8080: the exercise has no API server"; fi
if pgrep -x kube-apiserver >/dev/null 2>&1 || pgrep -x k3s >/dev/null 2>&1; then fail "an API server (kube-apiserver or k3s) runs on this machine"; fi
echo "  -> OK"

echo "[precondition] the readiness of the three pods as the kubelet judges it (its read-only /pods endpoint on 127.0.0.1:$KRO), and what the runtime's CRI says about the same pods..."
sudo env STATE_DIR="$STATE_DIR" KRO="$KRO" CTD_SOCK="$CTD_SOCK" python3 - <<'PYEOF' || exit 1
import json, os, subprocess, sys, urllib.request
E = os.environ
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
def kubelet():
    d = json.load(urllib.request.urlopen("http://127.0.0.1:%s/pods" % E["KRO"], timeout=3))
    out = {}
    for it in d["items"]:
        c = [x for x in it["status"].get("conditions", []) if x["type"] == "Ready"]
        out[it["metadata"]["name"]] = bool(c) and c[0]["status"] == "True"
    return out
def crictl(*a):
    return json.loads(subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CTD_SOCK"], "--image-endpoint", "unix://" + E["CTD_SOCK"]] + list(a) + ["-o", "json"], capture_output=True, text=True).stdout)
k = kubelet()
want = {"gate-node1": False, "steady-node1": True, "never-node1": False}
if k != want: fail("the kubelet judges %s, expected %s" % (k, want))
sb = {s["id"]: s for s in crictl("pods")["items"]}
cs = {c["id"]: c for c in crictl("ps", "-a")["containers"]}
for name, ids in st["pods"].items():
    if sb[ids["sandbox"]]["state"] != "SANDBOX_READY": fail("the sandbox of %s is not ready for the CRI" % name)
    if cs[ids["ctr"]]["state"] != "CONTAINER_RUNNING": fail("the container of %s is not running" % name)
print("  -> OK: kubelet %s; the CRI shows all three sandboxes SANDBOX_READY and all three containers CONTAINER_RUNNING: it cannot tell gate and never from steady" % ", ".join("%s=%s" % (n, "Ready" if v else "NotReady") for n, v in sorted(k.items())))
PYEOF

echo "[precondition] the control: opening the gate makes the kubelet judge gate Ready once the gate has stayed open for 3 s (the probe ignores a gate that is open or closed for less), closing it NotReady likewise, and a pulse of 2 s in either direction changes nothing..."
sudo env KRO="$KRO" GATE="$GATE" python3 - <<'PYEOF' || exit 1
import os, sys, time, urllib.request, json
E = os.environ
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
def ready(pod="gate-node1"):
    d = json.load(urllib.request.urlopen("http://127.0.0.1:%s/pods" % E["KRO"], timeout=3))
    for it in d["items"]:
        if it["metadata"]["name"] == pod:
            c = [x for x in it["status"].get("conditions", []) if x["type"] == "Ready"]
            return bool(c) and c[0]["status"] == "True"
flag = E["GATE"] + "/open"
def setgate(on):
    if on: open(flag, "w").close()
    elif os.path.exists(flag): os.unlink(flag)
def watch(seconds, events, want, label):
    t0 = time.time(); ev = sorted(events); flipped = None
    while time.time() - t0 < seconds:
        while ev and time.time() - t0 >= ev[0][0]: ev.pop(0)[1]()
        r = ready()
        if flipped is None and r != want[0]: flipped = round(time.time() - t0, 1)
        time.sleep(0.25)
    return flipped, ready()
def settle(on):
    setgate(on); t0 = time.time()
    while ready() != on:
        if time.time() - t0 > 30: fail("the kubelet did not judge gate %s within 30 s after the gate was %s" % ("Ready" if on else "NotReady", "opened" if on else "closed"))
        time.sleep(0.25)
    return round(time.time() - t0, 1)
# a passing probe once: the pod stays NotReady
flipped, end = watch(9, [(0.5, lambda: setgate(True)), (2.5, lambda: setgate(False))], (False,), "pulse")
if flipped is not None or end: fail("the gate open for only 2 s made the kubelet judge gate Ready: the probe of the lab does not behave as recorded")
t_up = settle(True)
flipped, end = watch(9, [(0.5, lambda: setgate(False)), (2.5, lambda: setgate(True))], (True,), "pulse")
if flipped is not None or not end: fail("the gate closed for only 2 s made the kubelet judge gate NotReady: the probe of the lab does not behave as recorded")
t_down = settle(False)
print("  -> OK: gate Ready %.1f s after it was opened, NotReady %.1f s after it was closed; a pulse of 2 s in either direction changes nothing; the gate is closed again" % (t_up, t_down))
PYEOF

echo "[precondition] the lab is as the task describes: a kubelet without an API server judges the pods' readiness, the runtime's CRI cannot tell the pods apart, and the gate is closed."
