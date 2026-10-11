#!/bin/bash
set -e

CASE_ID="bench71482106"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and its CRI answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py idle.c cni-stub.sh | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the node is as the lab recorded it: two pods with a sandbox each, four running containers, and a net namespace of its own per pod..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import sys

t = json.load(open(sys.argv[1]))
sb, c = t["sandboxes"], t["containers"]
assert len(sb) == 2 and len(c) == 4, "counts"
assert len({s["netns"] for s in sb.values()}) == 2, "the pods share a net namespace"
assert all(x["netns"] == sb[x["sandbox"]]["netns"] for x in c.values()), "a container is not in the net namespace of its pod"
assert len({x["pid"] for x in c.values()} | {s["pid"] for s in sb.values()}) == 6, "pids"
assert sorted(x["name"] for x in c.values()) == ["app", "db", "holder", "sidecar"], "names"
PYEOF
echo "  -> OK: shop/web-0 (containers app, sidecar) and shop/db-0 (containers db, holder), each pod in a net namespace of its own, each container in the one of its pod"

echo "[precondition] the problem: the sandboxes are not among the containers the CRI lists, and a process called pause is not always a sandbox..."
IDS=$("${CRI[@]}" ps -a -q --no-trunc)
[ "$(printf '%s\n' "$IDS" | grep -c .)" = 4 ] || fail "crictl ps -a does not list the four containers"
SB=$("${CRI[@]}" pods -q --no-trunc)
[ "$(printf '%s\n' "$SB" | grep -c .)" = 2 ] || fail "crictl pods does not list two sandboxes"
[ -z "$(comm -12 <(printf '%s\n' "$IDS" | sort) <(printf '%s\n' "$SB" | sort))" ] || fail "a sandbox is among the containers of crictl ps -a"
"${CRI[@]}" ps -a 2>/dev/null | awk 'NR > 1 { print $7 }' | grep -qx pause && fail "a container called pause is listed by crictl ps -a"
NP=$(pgrep -cx pause || true)
[ "$NP" = 3 ] || fail "$NP processes are called pause, not three (two sandboxes and a workload)"
echo "  -> OK: crictl ps -a lists 4 containers and no sandbox, crictl pods lists 2 sandboxes; 3 processes are called pause, but only 2 are sandboxes"
[ ! -e "$WORK_DIR/pause-map.sh" ] || fail "$WORK_DIR/pause-map.sh exists already"

echo "[precondition] ALL CHECKS PASSED: a CRI node with two pods whose pause processes crictl ps -a does not show, a workload that runs a program called pause too, and no pause-map.sh yet."
