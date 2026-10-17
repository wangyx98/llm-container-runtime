#!/bin/bash
set -e

CASE_ID="bench66642654"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ARGS="/var/lib/$CASE_ID/current/args"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them and the lab is as its record says (launcher, mk8sctl, registry, sandbox image, node)..."
sudo bash -c 'cd "$1" && sha256sum $(cat helpers.list) | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] neither the template nor the generated containerd.toml has a registry entry or a config_path yet..."
sudo grep -q "mirrors" "$ARGS/containerd-template.toml" "$ARGS/containerd.toml" && fail "a registry entry exists already"
sudo grep -E "^ *config_path = '.+'" "$ARGS/containerd-template.toml" "$ARGS/containerd.toml" >/dev/null && fail "a config_path is set already"
echo "  -> OK"

echo "[precondition] controls: the pull fails with the question's error; the asker's own try (an entry in containerd.toml, then a restart) is undone by the restart; a containerd with the same template and the entry pulls..."
OUT=$(sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" 2>&1) || { echo "$OUT" | tail -3; fail "see above"; }
echo "$OUT" | tail -3

echo "[precondition] PASS - the node cannot pull from the plain-HTTP registry; the controls work."
