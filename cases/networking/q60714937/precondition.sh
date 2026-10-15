#!/bin/bash
set -e

CASE_ID="bench60714937"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
GW="10.249.60.1"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the registry and the helpers are as setup left them; the cluster file and the script exist..."
P=$(cat "$WORK_DIR/registry.pid" 2>/dev/null || true)
[ -n "$P" ] && tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null | grep -q registry.py || fail "the registry of the lab is not running"
(cd "$STATE_DIR" && sha256sum mkoci.py registry.py lab.py verify.py create-cluster.sh app.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
[ "$(curl -s --noproxy '*' -A bench60714937-lab -o /dev/null -w '%{http_code}' "http://$GW:5000/v2/test/image/manifests/2.2.1")" = 200 ] || fail "the registry does not serve test/image:2.2.1 over plain HTTP on $GW:5000"
grep -q 'io.containerd.cri.v1.runtime' "$WORK_DIR/kind-cluster.yaml" || fail "the cluster file is not the one of setup"
echo "  -> OK: the registry serves $GW:5000/test/image:2.2.1 over plain HTTP"

echo "[precondition] the cluster: three nodes Ready; every node shows the HTTP mirror in config.toml and has no effective registry configuration; the cold CRI pull fails on every node;"
echo "               cache semantics: an image loaded into a node runs with IfNotPresent and fails with Always..."
python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "see above"

echo "[precondition] ALL CHECKS PASSED: a kind cluster whose three nodes show the HTTP mirror of the registry but pull over HTTPS (the registry table is under a plugin id containerd does not read for registries); a loaded image only hides it for IfNotPresent."
