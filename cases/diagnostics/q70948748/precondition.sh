#!/bin/bash
set -e

CASE_ID="bench70948748"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and its CRI answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py idle.c app.c cni-stub.sh | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the node is as the lab recorded it: two pods of the same name in two namespaces, two containers each with a tree of processes, a decoy process of the node..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" "$WORK_DIR/target.pid" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import sys

t = json.load(open(sys.argv[1]))
pods, cs = t["pods"], t["containers"]
assert len(pods) == 2 and {p["name"] for p in pods.values()} == {"api-0"}, "two pods of the same name"
assert {p["ns"] for p in pods.values()} == {"team-a", "team-b"} and len({p["uid"] for p in pods.values()}) == 2, "namespaces or UIDs"
assert len(cs) == 4 and sorted(c["name"] for c in cs.values()) == ["app", "app", "sidecar", "sidecar"], "containers"
allp = [q for c in cs.values() for q in c["procs"].values()]
assert len(allp) == 16 and len(set(allp)) == 16, "pids"
assert t["host"]["pid"] not in allp, "the decoy is a container process"
target = int(open(sys.argv[2]).read())
mine = [c for c in cs.values() if c["procs"]["grandchild"] == target]
assert len(mine) == 1 and pods[mine[0]["sandbox"]]["ns"] == "team-b" and mine[0]["name"] == "sidecar", "the target is not the grandchild of team-b/api-0 sidecar"
PYEOF
echo "  -> OK: team-a/api-0 and team-b/api-0 (containers app and sidecar each), 16 container processes, the decoy process of the node, target.pid = $(cat "$WORK_DIR/target.pid")"

echo "[precondition] the problem: crictl knows the first process of each container only, the target is deeper, and the pod name does not tell the pods apart..."
TARGET=$(cat "$WORK_DIR/target.pid")
INITS=$(for c in $("${CRI[@]}" ps -q --no-trunc); do "${CRI[@]}" inspect -o go-template --template '{{.info.pid}}' "$c"; done | tr '\n' ' ')
[ "$(printf '%s\n' $INITS | grep -c .)" = 4 ] || fail "crictl does not show four first processes"
printf '%s\n' $INITS | grep -qx "$TARGET" && fail "the target is a first process of a container"
NAMED=$("${CRI[@]}" ps -q --label io.kubernetes.pod.name=api-0 | wc -l)
[ "$NAMED" = 4 ] || fail "$NAMED containers are in pods named api-0, not four (two pods)"
HN=$(sudo nsenter -t "$TARGET" -u hostname 2>/dev/null) || fail "cannot read the host name of the target"
[ "$HN" = api-0 ] || fail "the host name of the target is $HN"
HP=$(python3 -c "import json;print(json.load(open('$STATE_DIR/truth.json'))['host']['pid'])")
sudo cat "/proc/$HP/environ" | tr '\0' '\n' | grep -qx 'HOSTNAME=api-0' || fail "the decoy has no HOSTNAME=api-0"
grep -qE '[0-9a-f]{64}' "/proc/$TARGET/cgroup" || fail "the cgroup of the target does not name a container"
! grep -qE '[0-9a-f]{64}' "/proc/$HP/cgroup" || fail "the decoy is in a container cgroup"
echo "  -> OK: the first processes are $INITS; the target $TARGET is none of them; its host name is $HN like that of the pods of both namespaces; the decoy $HP has HOSTNAME=api-0 and is in no container"
[ ! -e "$WORK_DIR/pid-owner.sh" ] || fail "$WORK_DIR/pid-owner.sh exists already"

echo "[precondition] ALL CHECKS PASSED: a CRI node with two pods of the same name in two namespaces, processes below the first process of each container, a decoy on the host, and no pid-owner.sh yet."
