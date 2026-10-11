#!/bin/bash
set -e

CASE_ID="bench67990667"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

CTR=(sudo ctr -a "$T_SOCK")
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and it answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py idle.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CTR[@]}" version >/dev/null 2>&1 || fail "ctr does not get an answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the node holds containers in three namespaces, the same IDs in different ones, some with a task and some without; the lab's record is what the node holds..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import sys

t = json.load(open(sys.argv[1]))
c = t["containers"]
assert len(t["namespaces"]) == 3 and len(c) == 6, "namespaces and containers"
ids = {}
for k in c:
    ids.setdefault(k.split("|")[1], []).append(k)
assert len(ids["web"]) == 2 and len(ids["api"]) == 3, "the same ID in several namespaces"
assert c[ids["web"][0]]["image"] != c[ids["web"][1]]["image"], "the two web containers must have different images"
for cid in ("web", "api"):
    assert len({v["labels"]["owner"] for k, v in c.items() if k.endswith("|" + cid)}) == len(ids[cid]), "labels of same-ID containers must differ"
st = [v["status"] for v in c.values()]
assert st.count("running") == 3 and st.count("none") == 3, "three running, three without a task"
assert all(v["pid"] for v in c.values() if v["status"] == "running") and all(v["pid"] is None for v in c.values() if v["status"] == "none")
assert len({v["pid"] for v in c.values() if v["pid"]}) == 3, "pids"
PYEOF
echo "  -> OK: $("${CTR[@]}" namespaces ls -q 2>/dev/null | grep -c "^$CASE_ID-") namespaces, $(for ns in $("${CTR[@]}" namespaces ls -q 2>/dev/null); do "${CTR[@]}" -n "$ns" containers ls -q 2>/dev/null; done | wc -l) containers, $(for ns in $("${CTR[@]}" namespaces ls -q 2>/dev/null); do "${CTR[@]}" -n "$ns" tasks ls -q 2>/dev/null; done | wc -l) tasks"

echo "[precondition] the problem: plain ctr shows no container (it looks at the namespace default), and a container's record has the image, runtime, labels and OCI spec but not the task..."
[ -z "$("${CTR[@]}" containers ls -q 2>/dev/null)" ] || fail "plain ctr shows containers"
NS=$(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["namespaces"])[0])' "$STATE_DIR/truth.json")
"${CTR[@]}" -n "$NS" containers info api 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["Image"] and d["Runtime"]["Name"] and d["Labels"] and d["Spec"]["process"]["env"] and d["Spec"]["mounts"]
assert "Pid" not in d and "Status" not in d and "Task" not in d, "the record has no task state"
' || fail "ctr containers info does not give a record as expected"
[ ! -e "$WORK_DIR/inspect.sh" ] || fail "$WORK_DIR/inspect.sh exists already"
echo "  -> OK: the containers are in the namespaces $(echo $("${CTR[@]}" namespaces ls -q 2>/dev/null | sed "s/^$CASE_ID-//")), 'ctr containers ls' shows none; the state of a task is in 'ctr tasks ls'"

echo "[precondition] ALL CHECKS PASSED: a node whose containerd holds containers in several namespaces (the same IDs in different ones, some with a task, some without), and there is no inspect.sh."
