#!/bin/bash
set -e

CASE_ID="bench62874903"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
LIB="/var/lib/$CASE_ID"
V="$STATE_DIR/verify"
IMAGE="localhost/$CASE_ID/app:local"

fail() { echo "  -> FAIL: $1"; exit 1; }
st() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]+"/state.json"))[sys.argv[2]])' "$STATE_DIR" "$1" 2>/dev/null; }
TOKEN=$(st token) || fail "setup's record is missing"

echo "[oracle] check 0: the recording programs, the drop-in, the configs and the image are as recorded; CRI-O still knows both handlers..."
sudo python3 - "$(sudo cat "$STATE_DIR/state.json")" <<'PYEOF' || fail "a recording program, the drop-in or a config was changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
sudo crictl inspecti "$IMAGE" 2>/dev/null | grep -q "$(st image_id)" || fail "CRI-O does not hold the case's image any more"
CFG=$(sudo crio config 2>/dev/null)
echo "$CFG" | grep -q '^\[crio.runtime.runtimes.benchrt\]' && echo "$CFG" | grep -q '^\[crio.runtime.runtimes.benchrt-verify\]' || fail "a runtime handler is not registered in CRI-O"
echo "  -> OK"

echo "[oracle] check 1: $WORK_DIR/contract.json exists, is JSON and has the fields handler, global_flags, commands, flags, operations, exec_process_keys, evidence..."
[ -f "$WORK_DIR/contract.json" ] || fail "contract.json does not exist"
python3 - "$WORK_DIR/contract.json" <<'PYEOF' || exit 1
import json, sys
try: c = json.load(open(sys.argv[1]))
except ValueError as e: print("  -> FAIL: contract.json is not JSON: %s" % e); sys.exit(1)
need = {"handler": str, "global_flags": list, "commands": list, "flags": dict, "operations": dict, "exec_process_keys": list, "evidence": dict}
for k, t in need.items():
    if not isinstance(c.get(k), t): print("  -> FAIL: field %s is missing or has the wrong type" % k); sys.exit(1)
if not isinstance(c["evidence"].get("container_id"), str) or not isinstance(c["evidence"].get("exec_args"), list):
    print("  -> FAIL: evidence needs container_id (string) and exec_args (list)"); sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] check 2: the evidence is in the job's log: the log's hash chain is intact, and it holds a 'create' and an 'exec' of the named container, the exec running  /bench-app echo <the token of this run>..."
sudo python3 - "$LIB/rt.log" "$WORK_DIR/contract.json" "$TOKEN" <<'PYEOF' || exit 1
import hashlib, json, sys
log, cj, token = sys.argv[1:4]
ev = json.load(open(cj))["evidence"]
recs, prev = [], ""
for n, l in enumerate(open(log), 1):
    if not l.strip(): continue
    r = json.loads(l); h = r.pop("h", None)
    if r.get("prev") != prev or r.get("seq") != len(recs) + 1 or hashlib.sha256(json.dumps(r, sort_keys=True).encode()).hexdigest() != h:
        print("  -> FAIL: the job's log was edited (its hash chain breaks at line %d)" % n); sys.exit(1)
    prev = h; recs.append(r)
def cmd(a):
    i = 0
    while i < len(a) and a[i].startswith("-"): i += 1 if "=" in a[i] else 2
    return a[i] if i < len(a) else ""
cid = ev["container_id"]
if not any(cmd(r["argv"]) == "create" and r["argv"][-1] == cid for r in recs): print("  -> FAIL: no 'create' of container %s in the job's log" % cid[:12]); sys.exit(1)
want = ["/bench-app", "echo", token]
if ev["exec_args"] != want: print("  -> FAIL: evidence.exec_args is %r, expected %r" % (ev["exec_args"], want)); sys.exit(1)
if not any(cmd(r["argv"]) == "exec" and r["argv"][-1] == cid and json.loads(r.get("process", "{}")).get("args") == want for r in recs):
    print("  -> FAIL: no 'exec' of container %s running %r in the job's log" % (cid[:12], want)); sys.exit(1)
PYEOF
echo "  -> OK"

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
echo "[oracle] check 3: three lifecycles (runp, create, start, exec, stop, rm, stopp, rmp) run now through the oracle's own handler give the true contract..."
sudo rm -f "$V/rt.log" "$V/marks.txt"
for i in 1 2 3; do
    sudo sh -c "sed 's/$CASE_ID-pod/$CASE_ID-v$i-pod/; s/$CASE_ID-uid/$CASE_ID-v$i-uid/' '$WORK_DIR/pod.json' > '$V/pod$i.json'; sed 's/$CASE_ID-ctr/$CASE_ID-v$i-ctr/' '$WORK_DIR/ctr.json' > '$V/ctr$i.json'"
    T() { local op=$1; shift; local a b; a=$(date +%s.%N); "$@"; local rc=$?; b=$(date +%s.%N); sudo sh -c "echo '$op $a $b' >> '$V/marks.txt'"; return $rc; }
    T runp  sudo crictl runp --runtime benchrt-verify "$V/pod$i.json" > "$TMPD/p" 2>/dev/null || fail "lifecycle $i: runp failed"
    P=$(tail -1 "$TMPD/p")
    T create sudo crictl create "$P" "$V/ctr$i.json" "$V/pod$i.json" > "$TMPD/c" 2>/dev/null || fail "lifecycle $i: create failed"
    C=$(tail -1 "$TMPD/c")
    T start sudo crictl start "$C" >/dev/null 2>&1 || fail "lifecycle $i: start failed"
    T exec  sudo crictl exec "$C" /bench-app echo "$TOKEN" >/dev/null 2>&1 || fail "lifecycle $i: exec failed"
    T stop  sudo crictl stop "$C" >/dev/null 2>&1 || fail "lifecycle $i: stop failed"
    T rm    sudo crictl rm "$C" >/dev/null 2>&1 || fail "lifecycle $i: rm failed"
    T stopp sudo crictl stopp "$P" >/dev/null 2>&1 || fail "lifecycle $i: stopp failed"
    T rmp   sudo crictl rmp "$P" >/dev/null 2>&1 || fail "lifecycle $i: rmp failed"
done
echo "  -> OK"

echo "[oracle] check 4: the contract.json of the job equals what the oracle's recording shows (commands, flags per command, global flags, the command of each operation, the keys of the exec's process spec)..."
sudo python3 - "$V/rt.log" "$V/marks.txt" "$WORK_DIR/contract.json" <<'PYEOF' || exit 1
import json, sys
log, marks, cj = sys.argv[1:4]
c = json.load(open(cj))
recs = [json.loads(l) for l in open(log) if l.strip()]
ops = [(m.split()[0], float(m.split()[1]), float(m.split()[2])) for m in open(marks) if m.strip()]
PAD = 0.002   # the recorder rounds its time to 1 ms; the steps are only a few ms apart on a fast machine, a wider margin would give a call to the neighbouring step
def split(a):
    g, i = [], 0
    while i < len(a) and a[i].startswith("-"):
        g.append(a[i].split("=")[0]); i += 1 if "=" in a[i] else 2
    return g, a[i], sorted({x for x in a[i + 1:] if x.startswith("-")})
t_cmds, t_flags, t_glob, t_keys = set(), {}, set(), set()
per_op = {}
for r in recs:
    g, cmd, f = split(r["argv"]); t_cmds.add(cmd); t_glob.update(g); t_flags.setdefault(cmd, set()).update(f)
    if "process" in r: t_keys.update(json.loads(r["process"]).keys())
    for op, a, b in ops:
        if a - PAD <= r["t"] <= b + PAD:
            per_op.setdefault(op, []).append(cmd)
# one list per operation: the commands every lifecycle had (state is CRI-O polling, left out)
by_run = {}
for n, (op, a, b) in enumerate(ops): by_run.setdefault(op, []).append(sorted({x for r in recs if a - PAD <= r["t"] <= b + PAD for x in [split(r["argv"])[1]] if x != "state"}))
bad = []
def same(name, got, want):
    if got != want: bad.append("%s: contract.json has %r, the recording shows %r" % (name, got, want))
same("global_flags", sorted(c["global_flags"]), sorted(t_glob))
same("commands", sorted(c["commands"]), sorted(t_cmds))
same("flags", {k: sorted(v) for k, v in c["flags"].items()}, {k: sorted(v) for k, v in t_flags.items()})
same("exec_process_keys", sorted(c["exec_process_keys"]), sorted(t_keys))
for op, runs in by_run.items():
    stable = runs[0] if all(r == runs[0] for r in runs) else None
    if stable is None: bad.append("operation %s: the recording is not stable between the lifecycles: %r" % (op, runs)); continue
    same("operations[%s]" % op, sorted(c["operations"].get(op, ["<missing>"])), stable)
if bad:
    print("  -> FAIL: " + "\n  -> FAIL: ".join(bad)); sys.exit(1)
print("  -> OK (commands %s; global flags %s; exec's process keys %s)" % (sorted(t_cmds), sorted(t_glob), sorted(t_keys)))
PYEOF

echo "[oracle] check 5: the oracle's lifecycles left nothing behind..."
[ -z "$(sudo crictl pods -q --name "$CASE_ID-v")" ] || fail "an oracle pod is still there"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
