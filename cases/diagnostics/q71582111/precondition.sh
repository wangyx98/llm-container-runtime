#!/bin/bash
set -e

CASE_ID="bench71582111"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

CTR=(sudo ctr -a "$T_SOCK")
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and it answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CTR[@]}" version >/dev/null 2>&1 || fail "ctr does not get an answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the node holds images in three namespaces, with several names for some, and the same name as two different images; the lab's record is what the node holds..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import sys

t = json.load(open(sys.argv[1]))["images"]
assert set(t) == {"default", "k8s.io", "ci"}, "namespaces"
web = "reg.bench71582111.invalid/shop/web:1"
assert t["default"][web] != t["k8s.io"][web], "the same name must be two images"
assert len(set(t["default"].values())) < len(t["default"]) and len(set(t["k8s.io"].values())) < len(t["k8s.io"]), "no image with two names"
assert len({d for v in t.values() for d in v.values()}) >= 6, "digests"
PYEOF
echo "  -> OK: default: $("${CTR[@]}" -n default images ls -q 2>/dev/null | wc -l) names, k8s.io: $("${CTR[@]}" -n k8s.io images ls -q 2>/dev/null | grep -vc '^sha256:') names (and the entries by image ID of the CRI), ci: $("${CTR[@]}" -n ci images ls -q 2>/dev/null | wc -l) names"

echo "[precondition] the problem: plain ctr shows the images of one namespace only, and what the kubelet uses is not among them..."
DEF=$("${CTR[@]}" images ls -q 2>/dev/null | sort)
[ "$DEF" = "$("${CTR[@]}" -n default images ls -q 2>/dev/null | sort)" ] || fail "plain ctr does not look at default"
! printf '%s\n' "$DEF" | grep -q 'shop/api' || fail "plain ctr shows the images of k8s.io"
[ ! -e "$WORK_DIR/list-images.sh" ] || fail "$WORK_DIR/list-images.sh exists already"
echo "  -> OK: 'ctr images ls' shows $(printf '%s\n' "$DEF" | grep -c .) names of the $(sudo ctr -a "$T_SOCK" namespaces ls -q 2>/dev/null | wc -l) namespaces"

echo "[precondition] ALL CHECKS PASSED: a node whose containerd holds images in several namespaces, plain ctr shows one of them, and there is no list-images.sh."
