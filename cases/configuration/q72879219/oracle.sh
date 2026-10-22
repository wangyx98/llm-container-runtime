#!/bin/bash
set -e

CASE_ID="bench72879219"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "[oracle] FAIL: $*"; exit 1; }

echo "[oracle] the lab is the lab's: containerd 1.6.6 (the unchanged binary), running, started from $LIB/etc/config.toml on the lab's socket..."
sudo "$LIB/bin/containerdctl" status >/dev/null || fail "containerd of the lab is not running"
sudo "$LIB/libexec/containerd" --version | grep -q "v1\.6\.6" || fail "containerd is not 1.6.6"
[ "$(sudo sha256sum "$LIB/libexec/containerd" | cut -d' ' -f1)" = "$(sudo cat "$STATE_DIR/containerd.sha")" ] || fail "the containerd binary was replaced"
PID=$(sudo cat "$RUN/containerd.pid")
[ "$(sudo readlink "/proc/$PID/exe")" = "$LIB/libexec/containerd" ] || fail "the process of the lab is not the containerd of the lab"
CMD=$(sudo tr '\0' ' ' 2>/dev/null < "/proc/$PID/cmdline")
echo "$CMD" | grep -q -- "--config $LIB/etc/config.toml " || fail "containerd was not started with --config $LIB/etc/config.toml: $CMD"
echo "$CMD" | grep -q -- "--address $RUN/containerd.sock" || fail "containerd does not listen on the socket of the lab: $CMD"
echo "  pid $PID: $(echo "$CMD" | sed 's|/var/lib/bench72879219/||g; s|/run/bench72879219/||g' | cut -c1-160)"

echo "[oracle] the running containerd uses what the node's configuration says (read from the live daemon through the CRI plugin): SELinux labels on, and the node's three other settings still in force..."
GOT=$(sudo "$(command -v crictl)" --runtime-endpoint "unix://$RUN/containerd.sock" --image-endpoint "unix://$RUN/containerd.sock" --timeout 60s info 2>&1 | python3 -c '
import json
import sys

try:
    c = json.load(sys.stdin)["config"]
    print("%s|%s|%s|%s" % (c.get("enableSelinux"), c.get("sandboxImage"), c["containerd"]["runtimes"]["runc"]["options"].get("SystemdCgroup"), c["registry"].get("configPath")))
except Exception as e:
    print("unreadable: %s" % e)') || true
IFS='|' read -r SEL IMG SDC CFGP <<<"$GOT"
[ "$SEL" = "True" ] || fail "the CRI plugin of the running containerd reports enableSelinux=$SEL (a container is still started without an SELinux label): $GOT"
[ "$IMG" = "registry.k8s.io/pause:3.9-lab" ] || fail "the sandbox image of the node is '$IMG', not registry.k8s.io/pause:3.9-lab: the node's other settings are no longer in force"
[ "$SDC" = "True" ] || fail "runc SystemdCgroup is '$SDC', not true: the node's other settings are no longer in force"
[ "$CFGP" = "$LIB/etc/certs.d" ] || fail "registry config_path is '$CFGP', not $LIB/etc/certs.d: the node's other settings are no longer in force"
echo "  enableSelinux=$SEL sandboxImage=$IMG SystemdCgroup=$SDC registry.config_path=$CFGP"

echo "[oracle] the configuration file still carries the engineer's four settings (it was edited, not replaced by a generated default)..."
sudo python3 - "$LIB/etc/config.toml" <<'PYEOF' || fail "config.toml lost one of the settings"
import re
import sys

t = open(sys.argv[1]).read()
for pat in (r"^\s*enable_selinux\s*=\s*true\s*$", r"^\s*sandbox_image\s*=\s*\"registry\.k8s\.io/pause:3\.9-lab\"\s*$", r"^\s*SystemdCgroup\s*=\s*true\s*$", r"^\s*config_path\s*=\s*\"/var/lib/bench72879219/etc/certs\.d\"\s*$"):
    assert re.search(pat, t, re.M), pat
PYEOF
echo "  enable_selinux, sandbox_image, SystemdCgroup and config_path are all in config.toml"

echo "[oracle] OK: the running containerd 1.6.6 honours enable_selinux = true, with the node's other settings in force"
