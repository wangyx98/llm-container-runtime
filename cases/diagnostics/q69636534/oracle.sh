#!/bin/bash
set -e

CASE_ID="bench69636534"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
T_CFG="$LIB_BASE/etc/containerd/config.toml"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SCRIPT="$WORK_DIR/pods.sh"             # what the solution has to write
NS_B="$CASE_ID-team-b"

CTR_T="sudo ctr -a $T_SOCK"
CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
cri_snapshot() {   # every pod sandbox and every container the CRI holds: id, state and metadata, one line each, sorted
    {
        "${CRI[@]}" pods -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    m = p["metadata"]
    print("pod", p["id"], p["state"], m["namespace"], m["name"], m["uid"], m["attempt"])'
        "${CRI[@]}" ps -a -o json | python3 -c '
import json, sys
for c in json.load(sys.stdin)["containers"]:
    m = c["metadata"]
    print("container", c["id"], c["state"], c["podSandboxId"], m["name"], m["attempt"])'
    } | LC_ALL=C sort
}
expected() {   # the right answer from the records (the files given): the pods that are READY, by uid, with the current (highest attempt) container of each name
    python3 - "$@" <<'PYEOF'
import json
import sys

out = {}
for f in sys.argv[1:]:
    for p in json.load(open(f)):
        if not p["ready"]:
            continue
        cur = {}
        for c in p["containers"]:
            if c["name"] not in cur or c["attempt"] > cur[c["name"]]["attempt"]:
                cur[c["name"]] = c
        out[p["uid"]] = {"namespace": p["namespace"], "name": p["name"], "containers": {n: c["id"] for n, c in sorted(cur.items())}}
print(json.dumps(out, sort_keys=True))
PYEOF
}

compare() {   # $1 = what the script printed, $2 = the expected answer (JSON, one line), $3 = a file with the records of every container (to name the ones that are wrong)
    python3 - "$1" "$2" "$3" <<'PYEOF'
import json
import sys

out_file, want_json, rec_files = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
raw = open(out_file, errors="replace").read()
try:
    got = json.loads(raw)
except ValueError as e:
    print("stdout is not one JSON document (%s): %r" % (e, raw[:160]))
    sys.exit(1)
want = json.loads(want_json)
info, cinfo = {}, {}
for f in rec_files:
    for p in json.load(open(f)):
        info[p["uid"]] = "%s/%s" % (p["namespace"], p["name"])
        for c in p["containers"]:
            cinfo[c["id"]] = "%s attempt %d" % (c["name"], c["attempt"])
if not isinstance(got, dict):
    print("the JSON is not an object keyed by pod uid: %r" % (raw[:160],))
    sys.exit(1)
problems = []
for u in sorted(set(want) - set(got)):
    problems.append("pod %s (uid %s) is missing" % (info.get(u, "?"), u))
for u in sorted(set(got) - set(want)):
    problems.append("uid %s is listed but it is not a pod running on the node (%s)" % (u, info.get(u, "unknown to the node") + (", stopped" if u in info else "")))
for u in sorted(set(want) & set(got)):
    g, w = got[u], want[u]
    if not isinstance(g, dict) or set(g) != {"namespace", "name", "containers"}:
        problems.append("pod %s: the entry does not have exactly the keys namespace, name and containers" % info[u])
        continue
    for k in ("namespace", "name"):
        if g[k] != w[k]:
            problems.append("pod %s: %s is %r, expected %r" % (info[u], k, g[k], w[k]))
    gc, wc = g["containers"], w["containers"]
    if not isinstance(gc, dict):
        problems.append("pod %s: containers is not an object name -> id" % info[u])
        continue
    for n in sorted(set(wc) - set(gc)):
        problems.append("pod %s: container %s is missing" % (info[u], n))
    for n in sorted(set(gc) - set(wc)):
        problems.append("pod %s: container %s is listed but the pod has none of that name" % (info[u], n))
    for n in sorted(set(wc) & set(gc)):
        if gc[n] != wc[n]:
            problems.append("pod %s: container %s has id %s (%s), expected the current instance %s (%s)" % (
                info[u], n, str(gc[n])[:12], cinfo.get(gc[n], "not a container of the node"), wc[n][:12], cinfo.get(wc[n], "?")))
if problems:
    print("; ".join(problems[:6]) + (" ..." if len(problems) > 6 else ""))
    sys.exit(1)
PYEOF
}
run_script() {   # $1 = output file: the script is run as the current user, no terminal, no input
    local rc=0
    timeout -k 3 90 bash "$SCRIPT" </dev/null >"$1" 2>"$1.err" || rc=$?
    [ "$rc" = 0 ] || fail "the script exited with $rc: $(head -c 300 "$1.err")"
}

echo "[oracle] check 0: the node's containerd is still the process of setup, its config is unchanged and it answers..."
alive_same t || fail "the node's containerd is not the process of setup (it was stopped, killed, restarted or replaced)"
[ "$(sudo sha256sum "$T_CFG" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the containerd config was changed"
for _ in $(seq 1 30); do "${CRI[@]}" version >/dev/null 2>&1 && break; sleep 1; done
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer"
echo "  -> OK"

echo "[oracle] check 1: the script $SCRIPT must exist, not be empty, and not contain any uid or id of the node (the node's ids are random: it has to find them)..."
[ -f "$SCRIPT" ] || fail "$SCRIPT does not exist"
[ -s "$SCRIPT" ] || fail "$SCRIPT is empty"
for id in $(python3 -c '
import json, re, sys
t = open(sys.argv[1]).read()
for m in sorted(set(re.findall(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{64}", t))):
    print(m)' "$STATE_DIR/pods.json"); do
    grep -qF "${id:0:12}" "$SCRIPT" && fail "the script contains the id $id of the node: it was written for this very node, not found by it"
done
echo "  -> OK ($(wc -l < "$SCRIPT") lines)"

echo "[oracle] check 2: the script, run as the current user without a terminal, must print exactly the pods running on the node as one JSON object: pod uid ->"
echo "[oracle]          {namespace, name, containers: {container name -> the id of its current instance}}; stopped pods out, restarted containers once..."
run_script "$WORK_DIR/answer1.json"
WANT1=$(expected "$STATE_DIR/pods.json")
MSG=$(compare "$WORK_DIR/answer1.json" "$WANT1" "$STATE_DIR/pods.json") || fail "$MSG"
echo "  -> OK ($(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$WANT1") pods)"

echo "[oracle] check 3: the script only looked: the CRI holds exactly what it held (no pod or container created, stopped or removed)..."
[ "$(cri_snapshot)" = "$(st cri.snapshot)" ] || fail "the pods or containers of the node were changed: $(diff <(st cri.snapshot) <(cri_snapshot) | grep '^[<>]' | head -2 | cut -c1-120 | tr '\n' ';')"
echo "  -> OK"

echo "[oracle] check 4: a pod that did not exist when the script was written: the oracle starts a NEW pod (random name, uid and a namespace of its own, a restarted"
echo "[oracle]          container with attempt 3, a second container), and the script, run again, must list it too..."
H=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
NEWUID=$(python3 -c 'import uuid; print(uuid.uuid4())')
python3 "$STATE_DIR/mkpod.py" "$T_SOCK" "$WORK_DIR" "$CASE_ID-new-$H" "n$H" "$NEWUID" 1 0 app:0:fail app:3:run side:1:run > "$WORK_DIR/hidden1.json" \
    || fail "the oracle could not start the new pod"
{ echo -n '['; cat "$WORK_DIR/hidden1.json"; echo ']'; } > "$STATE_DIR/hidden.json"
rm -f "$WORK_DIR/hidden1.json"
run_script "$WORK_DIR/answer2.json"
WANT2=$(expected "$STATE_DIR/pods.json" "$STATE_DIR/hidden.json")
MSG=$(compare "$WORK_DIR/answer2.json" "$WANT2" "$STATE_DIR/pods.json,$STATE_DIR/hidden.json") || fail "after a new pod was started: $MSG"
echo "  -> OK (the new pod $NEWUID is in the answer)"

echo "[oracle] check 5: the pods and containers of the node are still what they were (the new pod is the only addition), and the daemon is the same..."
comm -23 <(st cri.snapshot) <(cri_snapshot) | grep -q . && fail "something that existed before was changed or removed: $(comm -23 <(st cri.snapshot) <(cri_snapshot) | head -1 | cut -c1-120)"
alive_same t || fail "the node's containerd was replaced meanwhile"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED"
