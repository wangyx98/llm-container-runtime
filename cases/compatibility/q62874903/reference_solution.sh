#!/bin/bash
# The contract is what CRI-O's monitor really runs: use the handler "benchrt" (its program logs every command line and the process spec of an exec), run one lifecycle
# with the given configs, execute the token with the container's own program, note how many log lines each crictl step added, then turn the log into contract.json.
set -e
W=/tmp/bench62874903
LOG=/var/lib/bench62874903/rt.log
TOKEN=$(cat $W/token)
: > $W/steps.txt
step() { local n=$1 a b; shift; a=$(wc -l < $LOG); "$@" > $W/step.out; b=$(wc -l < $LOG); echo "$n $a $b" >> $W/steps.txt; }
step runp   sudo crictl runp --runtime benchrt $W/pod.json;            P=$(tail -1 $W/step.out)
step create sudo crictl create $P $W/ctr.json $W/pod.json;             C=$(tail -1 $W/step.out)
step start  sudo crictl start $C
step exec   sudo crictl exec $C /bench-app echo "$TOKEN"
step stop   sudo crictl stop $C
step rm     sudo crictl rm $C
step stopp  sudo crictl stopp $P
step rmp    sudo crictl rmp $P
python3 - $LOG $W/steps.txt $W/contract.json "$C" "$TOKEN" <<'PYEOF'
import json, sys
log, steps, out, cid, token = sys.argv[1:6]
recs = [json.loads(l) for l in open(log)]
def split(a):
    g, i = [], 0
    while i < len(a) and a[i].startswith("-"):
        g.append(a[i].split("=")[0]); i += 1 if "=" in a[i] else 2
    return g, a[i], sorted({x for x in a[i + 1:] if x.startswith("-")})
cmds, flags, glob, keys, ops = set(), {}, set(), set(), {}
for r in recs:
    g, c, f = split(r["argv"]); glob.update(g); cmds.add(c); flags.setdefault(c, set()).update(f)
    if "process" in r: keys.update(json.loads(r["process"]).keys())
for l in open(steps):
    n, a, b = l.split()
    ops[n] = sorted({split(r["argv"])[1] for r in recs[int(a):int(b)]} - {"state"})   # state: CRI-O polling
exec_args = [json.loads(r["process"])["args"] for r in recs if "process" in r][-1]
json.dump({"handler": "benchrt", "global_flags": sorted(glob), "commands": sorted(cmds), "flags": {c: sorted(v) for c, v in sorted(flags.items())},
           "operations": ops, "exec_process_keys": sorted(keys), "evidence": {"container_id": cid, "exec_args": exec_args}}, open(out, "w"), indent=1)
PYEOF
echo "[reference] contract.json written"
