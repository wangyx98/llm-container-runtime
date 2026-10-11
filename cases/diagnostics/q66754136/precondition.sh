#!/bin/bash
set -e

CASE_ID="bench66754136"
RUN_BASE="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

CTR=(sudo ctr -a "$T_SOCK")
fail() { echo "  -> FAIL: $*"; exit 1; }
HELPERS="patch_config.py mkimg.py lab.py verify.py"

echo "[precondition] the node's containerd runs, the helpers are as setup copied them, and it answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum $HELPERS | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
"${CTR[@]}" version >/dev/null 2>&1 || fail "ctr does not get an answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] the node holds images in k8s.io (refs with kafka in them, and refs that look alike) and in default; the lab's record is what the node holds..."
python3 "$STATE_DIR/lab.py" check "$T_SOCK" "$WORK_DIR" || fail "see above"
python3 - "$STATE_DIR/truth.json" <<'PYEOF' || fail "the record of the lab is not what the case is built on"
import json
import sys

t = json.load(open(sys.argv[1]))["images"]
assert set(t) == {"k8s.io", "default"}, "namespaces"
k = [r for r in t["k8s.io"] if "kafka" in r]
assert len(k) == 5, "five refs of k8s.io with kafka in them"
assert len([r for r in t["default"] if "kafka" in r]) == 2, "two refs of default with kafka in them"
assert sum("bitnami/kafka:2.7.0" in r for r in t["k8s.io"]) == 1 and "registry.local/bitnami/kafka:2-7-0" in t["k8s.io"], "the dot trap"
assert any("dio/" in r and ".io/" not in r for r in t["k8s.io"]), "the .io/ trap"
PYEOF
echo "  -> OK: k8s.io: $("${CTR[@]}" -n k8s.io images ls -q 2>/dev/null | grep -vc '^sha256:') refs (and the entries by image ID of the CRI), default: $("${CTR[@]}" -n default images ls -q 2>/dev/null | wc -l) refs"

echo "[precondition] the problem: plain ctr shows the namespace default, a filter on a field that does not exist (ref) silently lists nothing, and the text of a ref is not a plain text in a regular expression..."
DEF=$("${CTR[@]}" images ls -q 2>/dev/null | sort)
[ "$DEF" = "$("${CTR[@]}" -n default images ls -q 2>/dev/null | sort)" ] || fail "plain ctr does not look at default"
! printf '%s\n' "$DEF" | grep -q 'zookeeper' || fail "plain ctr shows the images of k8s.io"
ALL=$("${CTR[@]}" -n k8s.io images ls -q 2>/dev/null | grep -c kafka)
REF=$("${CTR[@]}" -n k8s.io images ls -q 'ref~=kafka' 2>/dev/null | wc -l)
[ "$ALL" = 5 ] && [ "$REF" = 0 ] || fail "ref~=kafka lists $REF refs (grep finds $ALL)"
RAW=$("${CTR[@]}" -n k8s.io images ls -q 'name~="bitnami/kafka:2.7.0"' 2>/dev/null | wc -l)
[ "$RAW" = 2 ] || fail "the text bitnami/kafka:2.7.0 as a regular expression lists $RAW refs, not the 2 of the dot trap"
[ ! -e "$WORK_DIR/ref-filter.sh" ] || fail "$WORK_DIR/ref-filter.sh exists already"
echo "  -> OK: 'ctr images ls' shows default only; 'ref~=kafka' lists 0 of the $ALL refs of k8s.io with kafka in them; the text bitnami/kafka:2.7.0 unescaped lists 2 refs, only 1 contains it"

echo "[precondition] ALL CHECKS PASSED: a node whose containerd holds images in k8s.io and default, a ref filter that is easy to get wrong, and there is no ref-filter.sh."
