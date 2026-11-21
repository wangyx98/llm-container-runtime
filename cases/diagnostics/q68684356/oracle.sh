#!/bin/bash
set -e

CASE_ID="bench68684356"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CTD_SOCK="$RUN_BASE/containerd.sock"
GATE="$LIB_BASE/gate"
MANIFESTS="$LIB_BASE/manifests"
TOOL="$WORK_DIR/bin/pod-ready"

sj() { sudo python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[k]
print(v if not isinstance(v, (dict, list)) else json.dumps(v))' "$STATE_DIR/state.json" "$1"; }
fail() { echo "  -> FAIL: $*"; exit 1; }
KRO=$(sj kro)

lab_ok() {   # the node as setup left it: files and manifests, the two processes, the pods' sandboxes and containers, the kubelet answering
    sudo env STATE_DIR="$STATE_DIR" MANIFESTS="$MANIFESTS" RUN_BASE="$RUN_BASE" CTD_SOCK="$CTD_SOCK" KRO="$KRO" python3 - <<'PYEOF' || exit 1
import hashlib, json, os, subprocess, sys, urllib.request
E = os.environ
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
st = json.load(open(E["STATE_DIR"] + "/state.json"))
for f, h in st["files"].items():
    try: now = hashlib.sha256(open(f, "rb").read()).hexdigest()
    except OSError: fail("%s is gone (the node's files, the kubelet's configuration, the pods' manifests and the probes stay as setup made them)" % f)
    if now != h: fail("%s was changed (the node's files, the kubelet's configuration, the pods' manifests and the probes stay as setup made them)" % f)
if sorted(os.listdir(E["MANIFESTS"])) != st["manifests"]: fail("a static pod manifest was added or removed")
for name in ("containerd", "kubelet"):
    try:
        pid = int(open("%s/%s.pid" % (E["RUN_BASE"], name)).read())
        comm = open("/proc/%d/comm" % pid).read().strip()
        stat = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()
        start = stat[19]
        if stat[0] in ("Z", "X"): raise OSError("dead")
    except Exception: fail("the node's %s is not running" % name)
    if comm != name or pid != st[name]["pid"] or start != st[name]["start"]: fail("the node's %s was restarted or replaced (it runs on as setup started it)" % name)
def crictl(*a):
    return json.loads(subprocess.run(["crictl", "--runtime-endpoint", "unix://" + E["CTD_SOCK"], "--image-endpoint", "unix://" + E["CTD_SOCK"]] + list(a) + ["-o", "json"], capture_output=True, text=True).stdout or "{}")
sb = {s["id"]: s for s in crictl("pods").get("items", [])}
cs = {c["id"]: c for c in crictl("ps", "-a").get("containers", [])}
for name, ids in st["pods"].items():
    if ids["sandbox"] not in sb or sb[ids["sandbox"]]["state"] != "SANDBOX_READY": fail("the sandbox of %s is gone or not ready (the pods are not to be recreated)" % name)
    if ids["ctr"] not in cs or cs[ids["ctr"]]["state"] != "CONTAINER_RUNNING": fail("the container of %s is gone or not running (the pods are not to be recreated or restarted)" % name)
try: urllib.request.urlopen("http://127.0.0.1:%s/pods" % E["KRO"], timeout=3).read()
except Exception as e: fail("the kubelet does not answer on its read-only port (%s)" % e)
PYEOF
}

echo "[oracle] checking the node is as the setup left it (files, manifests and probes unchanged; containerd and kubelet the same processes; the three pods the same sandboxes and containers)..."
lab_ok
[ -e "$TOOL" ] || fail "$TOOL does not exist: no pod-ready was made"
[ -x "$TOOL" ] || fail "$TOOL is not executable"
echo "  -> OK"

echo "[oracle] following the readiness of the pods while the gate is opened and closed: at every moment pod-ready must say what the kubelet has judged (it may follow a change within 1.8 s), for gate, steady and never; a gate that is open (or closed) for only 2 s changes nothing..."
env TOOL="$TOOL" GATE="$GATE" KRO="$KRO" python3 - <<'PYEOF' || exit 1
import json, os, subprocess, sys, time, urllib.request
E = os.environ
TOOL, GATE = E["TOOL"], E["GATE"]
KURL = "http://127.0.0.1:%s/pods" % E["KRO"]
G, S, N = "gate-node1", "steady-node1", "never-node1"
FLAG = GATE + "/open"
GRACE = 1.8
def fail(m): print("  -> FAIL: " + m); sys.exit(1)
def labfail(m): print("  -> FAIL: the lab does not behave as recorded: " + m); sys.exit(1)
def kubelet():
    try: d = json.load(urllib.request.urlopen(KURL, timeout=3))
    except Exception as e: fail("the kubelet of the node does not answer (%s)" % e)
    out = {}
    for it in d.get("items", []):
        c = [x for x in (it.get("status") or {}).get("conditions", []) if x.get("type") == "Ready"]
        out[it["metadata"]["name"]] = bool(c) and c[0].get("status") == "True"
    return out
def ask(pod):
    try: p = subprocess.run([TOOL, pod], capture_output=True, text=True, timeout=10)
    except subprocess.TimeoutExpired: fail("pod-ready %s did not answer within 10 s" % pod)
    except OSError as e: fail("pod-ready cannot be run: %s" % e)
    return p.stdout.strip(), p.returncode, p.stderr.strip()[-160:]
def say(pod):
    out, rc, err = ask(pod)
    if rc != 0 or out not in ("true", "false"): fail("pod-ready %s printed %r and exited %d (its stderr: %s): it must print true or false and exit 0" % (pod, out[:60], rc, err))
    return out == "true"
def setgate(on):
    if on: open(FLAG, "w").close()
    elif os.path.exists(FLAG): os.unlink(FLAG)
last, changed = {}, {}
def sample(label, stay=None):   # the kubelet is read before and after the three answers: a change in between may show in either
    k1 = kubelet(); a = time.time()
    ts = {}
    for p in (G, S, N):
        if p not in k1: fail("the kubelet does not list the pod %s any more" % p)
        ts[p] = say(p)
    k = kubelet(); now = time.time()
    for p in (G, S, N):
        if p not in k: fail("the kubelet does not list the pod %s any more" % p)
        for val, tm in ((k1[p], a), (k[p], now)):
            if p not in last: changed[p] = tm - 100   # settled since before the test began
            elif val != last[p]: changed[p] = tm
            last[p] = val
    if stay and k[stay[0]] != stay[1]: labfail("%s: the kubelet judged %s %s after the gate was open or closed for only 2 s" % (label, stay[0], "Ready" if k[stay[0]] else "NotReady"))
    for p in (G, S, N):
        if k1[p] == k[p] and ts[p] != k[p] and now - changed[p] >= GRACE:
            fail("%s: pod-ready %s says %s, but the kubelet has judged the pod %s%s" % (label, p, str(ts[p]).lower(), "Ready" if k[p] else "NotReady", " for the last %.1f s" % (now - changed[p]) if now - changed[p] < 50 else " all along"))
    return k
def run(seconds, events, label, until=None, stay=None):   # until = (pod, value): stop 2.5 s after the kubelet judged it so
    t0 = time.time(); ev = sorted(events, key=lambda e: e[0]); n = 0
    while True:
        el = time.time() - t0
        while ev and el >= ev[0][0]: ev.pop(0)[1]()
        k = sample(label, stay); n += 1
        if until and k[until[0]] == until[1] and time.time() - changed[until[0]] >= 2.5: return n
        if el > seconds:
            if until: labfail("%s: the kubelet did not judge %s %s within %d s" % (label, until[0], "Ready" if until[1] else "NotReady", seconds))
            return n
        time.sleep(0.1)
if os.path.exists(FLAG): os.unlink(FLAG)
k0 = kubelet()
deadline = time.time() + 25
while k0.get(G) is not False and time.time() < deadline: time.sleep(0.5); k0 = kubelet()
if (k0.get(G), k0.get(S), k0.get(N)) != (False, True, False): labfail("at the start the kubelet judges %s, expected gate NotReady, steady Ready, never NotReady" % k0)
out, rc, err = ask("no-such-pod-node1")
if rc == 0 or out in ("true", "false"): fail("pod-ready answers %r (exit %d) for a pod the node does not have: it must exit non-zero and print neither true nor false" % (out[:40], rc))
n = sample("at the start")
tot = 1
tot += run(30, [(0.3, lambda: setgate(True))], "the gate opened", until=(G, True))
tot += run(30, [(0.3, lambda: setgate(False))], "the gate closed", until=(G, False))
tot += run(11, [(0.5, lambda: setgate(True)), (2.5, lambda: setgate(False))], "the gate opened for 2 s", stay=(G, False))
tot += run(30, [(0.3, lambda: setgate(True))], "the gate opened again", until=(G, True))
tot += run(11, [(0.5, lambda: setgate(False)), (2.5, lambda: setgate(True))], "the gate closed for 2 s", stay=(G, True))
tot += run(30, [(0.3, lambda: setgate(False))], "the gate closed again", until=(G, False))
print("  -> OK: %d rounds of three answers each agreed with the kubelet (gate: NotReady, Ready, NotReady, a pulse of the gate open for 2 s that changed nothing, Ready, a pulse of the gate closed for 2 s that changed nothing, NotReady; steady always Ready, never always NotReady); a pod the node does not have is refused" % tot)
PYEOF

echo "[oracle] the node is still as the setup left it after the whole sequence (no file, probe, process, sandbox or container was changed or replaced)..."
lab_ok
echo "  -> OK"
echo "[oracle] PASS: pod-ready tells the readiness of a pod as the node's kubelet judges it, from the kubelet (the CRI shows every sandbox Ready and every container running all the time), without an API server and without touching the node."
