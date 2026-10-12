#!/bin/bash
set -e

CASE_ID="bench74592511"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="/run/containerd/containerd.sock"
DEV="bench74592511-dev"
OTHER="bench74592511-other"

fail() { echo "[precondition] FAIL: $*"; exit 1; }

echo "[precondition] the socket belongs to root:root with mode 660, and containerd's config names no [grpc] gid..."
[ "$(stat -c '%U:%G %a' "$SOCK")" = "root:root 660" ] || fail "the socket is $(stat -c '%U:%G %a' "$SOCK"), not root:root 660"
if sudo python3 - <<'PYEOF'
import re
t = open("/etc/containerd/config.toml").read()
m = re.search(r'(?ms)^\[grpc\](.*?)(?=^\[|\Z)', t)
g = re.search(r'(?m)^\s*gid\s*=\s*(\d+)', m.group(1)) if m else None
raise SystemExit(0 if (g and g.group(1) != "0") else 1)
PYEOF
then fail "the config already sets a [grpc] gid"; fi

echo "[precondition] control: root gets a real answer from the CRI (the daemon is healthy)..."
sudo crictl info >/dev/null 2>&1 || fail "root's crictl info fails: the CRI itself is broken"

echo "[precondition] crictl is configured for the socket..."
grep -q "^runtime-endpoint: unix://$SOCK" /etc/crictl.yaml || fail "/etc/crictl.yaml does not point at $SOCK"

for u in "$DEV" "$OTHER"; do
    echo "[precondition] $u: exists, in none of root/sudo/wheel, no sudo rights, and denied by the socket..."
    id "$u" >/dev/null 2>&1 || fail "$u does not exist"
    if id -nG "$u" | grep -qwE "root|sudo|wheel"; then fail "$u is already in root/sudo/wheel"; fi
    sudo -n -l -U "$u" 2>&1 | grep -q "not allowed to run sudo" || fail "$u already has sudo rights"
    out=$(sudo -n -u "$u" -H crictl info 2>&1) && fail "$u can already run crictl info before any fix"
    echo "$out" | grep -qi "permission denied" || fail "$u is refused, but not for permissions: $(echo "$out" | tail -1 | cut -c1-150)"
done

[ -s "$STATE_DIR/helpers.sha" ] || fail "the helpers of the oracle are missing"
echo "[precondition] PASS - the CRI works for root, and both users are denied by the permissions of the socket."
