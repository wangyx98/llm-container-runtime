#!/bin/bash
set -e

CASE_ID="bench61055917"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
O_SOCK="$RUN_BASE/docker/containerd.sock"

CTR=(sudo ctr -a "$T_SOCK")
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and it answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py idle.c tap.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CTR[@]}" version >/dev/null 2>&1 || fail "ctr does not get an answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the socket of the other containerd is there and nothing has connected to it (this check does not connect either)..."
[ -S "$O_SOCK" ] || fail "$O_SOCK is not a socket"
[ -f "$STATE_DIR/tap.log" ] && [ ! -s "$STATE_DIR/tap.log" ] || fail "something has connected to the other socket already"
echo "  -> OK"

echo "[precondition] the node holds its workload in the namespace k8s.io: images (two with the same name and tag from different registries) and containers with a task and one without; the lab's record is what the node holds..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import re
import sys

t = json.load(open(sys.argv[1]))
c, im = t["containers"], t["images"]
assert t["namespaces"] == ["k8s.io"], "the node has only the namespace k8s.io"
assert len(c) == 6 and len(im) == 5, "six containers, five images"
assert all(re.fullmatch(r"[0-9a-f]{64}", k) for k in c), "kubelet style IDs"
pids = [v["pid"] for v in c.values()]
assert sum(1 for p in pids if p) == 5 and pids.count(None) == 1, "five tasks, one container without"
assert len({p for p in pids if p}) == 5, "pids"
pauses = [r for r in im if r.endswith("/pause:3.1")]
assert len(pauses) == 2 and len({im[r] for r in pauses}) == 2, "two images with the name pause:3.1, different digests"
assert len(set(im.values())) == 5, "five digests"
used = {v["image"] for v in c.values()}
assert len(set(im) - used) == 1, "exactly one image no container uses"
assert all(v["digest"] == im[v["image"]] for v in c.values())
PYEOF
echo "  -> OK: $("${CTR[@]}" -n k8s.io images ls -q 2>/dev/null | grep -vc "^sha256:") images, $("${CTR[@]}" -n k8s.io containers ls -q 2>/dev/null | wc -l) containers, $("${CTR[@]}" -n k8s.io tasks ls -q 2>/dev/null | wc -l) tasks"

echo "[precondition] the problem: ctr looks at the namespace default, which is empty; the workload is in k8s.io, and 'containers ls' shows neither digest nor PID..."
[ -z "$("${CTR[@]}" containers ls -q 2>/dev/null)" ] || fail "plain ctr shows containers"
[ -z "$("${CTR[@]}" images ls -q 2>/dev/null)" ] || fail "plain ctr shows images"
"${CTR[@]}" namespaces ls -q 2>/dev/null | grep -qx k8s.io || fail "the namespace k8s.io is not listed"
HEAD=$("${CTR[@]}" -n k8s.io containers ls 2>/dev/null | head -1 | awk '{print $1,$2,$3}')
[ "$HEAD" = "CONTAINER IMAGE RUNTIME" ] || fail "the columns of 'containers ls' are: $HEAD"
[ ! -e "$WORK_DIR/list-node.sh" ] || fail "$WORK_DIR/list-node.sh exists already"
echo "  -> OK: 'ctr containers ls' and 'ctr images ls' show nothing; with -n k8s.io the containers have the columns CONTAINER IMAGE RUNTIME (no PID, no digest); the PID is in 'tasks ls', the digest in 'images ls'"

echo "[precondition] ALL CHECKS PASSED: a MicroK8s-like node (own containerd, empty default namespace, the workload in k8s.io, another socket on the host that must stay untouched), and there is no list-node.sh."
