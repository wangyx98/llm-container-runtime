#!/bin/bash
set -e

CASE_ID="bench71705752"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and its CRI answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the node is as the lab recorded it: three pods, two running rabbitmq containers of the same name and one finished job, three images..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import sys

t = json.load(open(sys.argv[1]))
c = list(t["containers"].values())
rab = [x for x in c if x["name"] == "rabbitmq"]
assert len(c) == 3 and len(t["pods"]) == 3 and len(t["images"]) == 3, "counts"
assert len(rab) == 2 and {x["ns"] for x in rab} == {"prod", "staging"} and {x["pod"] for x in rab} == {"rabbitmq-0"}, "the rabbitmq containers"
assert len({x["token"] for x in rab}) == 2 and {x["uid"] for x in rab} == {1001, 1002}, "tokens or users"
assert [x["state"] for x in c if x["name"] == "job"] == ["CONTAINER_EXITED"], "the job"
PYEOF
echo "  -> OK: prod/rabbitmq-0 (user 1001) and staging/rabbitmq-0 (user 1002) run a container rabbitmq each, prod/job-0 has finished, each rabbitmq container has a token of its own"

echo "[precondition] the problem: plain ctr (the default containerd namespace) shows nothing, although the node runs containers and has images..."
[ -z "$(sudo ctr -a "$T_SOCK" containers ls -q 2>/dev/null)" ] || fail "plain ctr lists containers"
[ -z "$(sudo ctr -a "$T_SOCK" images ls -q 2>/dev/null)" ] || fail "plain ctr lists images"
[ -n "$(sudo ctr -a "$T_SOCK" -n k8s.io containers ls -q 2>/dev/null)" ] || fail "the namespace k8s.io has no containers"
echo "  -> OK: 'ctr containers ls' and 'ctr images ls' print nothing"
[ ! -e "$WORK_DIR/inspect-node.sh" ] || fail "$WORK_DIR/inspect-node.sh exists already"

echo "[precondition] ALL CHECKS PASSED: a CRI node whose pods and images plain ctr does not show, two containers of the same name in two Kubernetes namespaces, and no inspect-node.sh yet."
