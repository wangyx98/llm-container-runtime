#!/bin/bash
set -e

CASE_ID="bench72879219"
RUN="/run/$CASE_ID"
LIB="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
CRICTL="$LIB/bin/crictl"
CTL="$STATE_DIR/ctl"

fail() { echo "[precondition] FAIL: $*"; exit 1; }
# what a running containerd's CRI plugin reports: enableSelinux|sandboxImage|SystemdCgroup|registry config_path   ($1 = the CRI endpoint socket)
cri_view() {
    sudo "$(command -v crictl)" --runtime-endpoint "unix://$1" --image-endpoint "unix://$1" --timeout 60s info | python3 -c '
import json
import sys

c = json.load(sys.stdin)["config"]
print("%s|%s|%s|%s" % (c.get("enableSelinux"), c.get("sandboxImage"), c["containerd"]["runtimes"]["runc"]["options"].get("SystemdCgroup"), c["registry"].get("configPath")))'
}
WANT="True|registry.k8s.io/pause:3.9-lab|True|$LIB/etc/certs.d"

echo "[precondition] the lab: containerd 1.6.6 with the CRI plugin, started with the node's configuration file..."
sudo "$LIB/bin/containerdctl" status >/dev/null || fail "containerd of the lab is not running"
sudo "$LIB/libexec/containerd" --version | grep -q "v1\.6\.6" || fail "containerd is not 1.6.6"
PID=$(sudo cat "$RUN/containerd.pid")
CMD=$(sudo tr '\0' ' ' 2>/dev/null < "/proc/$PID/cmdline")
echo "$CMD" | grep -q -- "--config $LIB/etc/config.toml " || fail "containerd was not started with --config $LIB/etc/config.toml: $CMD"
sudo grep -qE '^[[:space:]]*enable_selinux[[:space:]]*=[[:space:]]*true' "$LIB/etc/config.toml" || fail "config.toml does not say enable_selinux = true"
! sudo grep -qE '^[[:space:]]*version[[:space:]]*=' "$LIB/etc/config.toml" || fail "config.toml already has a version"
echo "  $(sudo "$LIB/libexec/containerd" --version | awk '{print $3}'), pid $PID, config.toml says enable_selinux = true and has no version"

echo "[precondition] the problem: the running containerd does not use what config.toml says (SELinux labels of containers are off, and so are the node's other three settings)..."
GOT=$(cri_view "$RUN/containerd.sock") || fail "crictl info of the lab failed"
[ "$GOT" != "$WANT" ] || fail "the running containerd already has the settings of config.toml"
IFS='|' read -r SEL IMG SDC CFGP <<<"$GOT"
[ "$SEL" = "False" ] || fail "enableSelinux is $SEL, expected False before the fix"
[ "$IMG" != "registry.k8s.io/pause:3.9-lab" ] || fail "the sandbox image of config.toml is already in force"
[ "$SDC" != "True" ] || fail "SystemdCgroup of config.toml is already in force"
[ "$CFGP" != "$LIB/etc/certs.d" ] || fail "the registry config_path of config.toml is already in force"
echo "  CRI plugin: enableSelinux=$SEL sandboxImage=$IMG SystemdCgroup=$SDC registry.config_path='$CFGP'  (config.toml: true, pause:3.9-lab, true, $LIB/etc/certs.d)"

echo "[precondition] control: a second, throw-away containerd 1.6.6 with the same file plus one line 'version = 2' on top uses all four settings..."
sudo rm -rf "$CTL"
sudo install -d -m 700 "$CTL" "$CTL/root" "$CTL/state"
{ echo "version = 2"; sudo cat "$LIB/etc/config.toml"; } | sudo tee "$CTL/config.toml" >/dev/null
sudo sh -c "PATH='$LIB/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' setsid nohup '$LIB/libexec/containerd' --config '$CTL/config.toml' --root '$CTL/root' --state '$CTL/state' --address '$CTL/c.sock' >'$CTL/containerd.log' 2>&1 </dev/null &"
for i in $(seq 1 60); do sudo test -S "$CTL/c.sock" && sudo "$LIB/libexec/ctr" -a "$CTL/c.sock" version >/dev/null 2>&1 && break; sleep 0.5; done
CGOT=$(cri_view "$CTL/c.sock") || { sudo pkill -KILL -f -- "--address $CTL/[c].sock" 2>/dev/null; fail "crictl info of the control instance failed: $(sudo tail -3 "$CTL/containerd.log")"; }
CPID=$(sudo pgrep -f -- "--address $CTL/[c].sock" | head -1)
[ -n "$CPID" ] && sudo kill -TERM "$CPID" 2>/dev/null
for i in $(seq 1 20); do sudo pgrep -f -- "--address $CTL/[c].sock" >/dev/null || break; sleep 0.5; done
sudo pkill -KILL -f -- "--address $CTL/[c].sock" 2>/dev/null || true
sudo rm -rf "$CTL"
[ "$CGOT" = "$WANT" ] || fail "the control instance does not show the settings of the file: $CGOT"
echo "  control: $CGOT"

echo "[precondition] OK: containerd ignores the CRI settings of config.toml as it is, and the same content with 'version = 2' works"
