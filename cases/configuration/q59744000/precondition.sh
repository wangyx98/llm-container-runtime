#!/bin/bash
set -e

CASE_ID="bench59744000"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
ETC="$LIB_BASE/etc"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"

CRI=(sudo crictl --runtime-endpoint "unix://$T_SOCK" --image-endpoint "unix://$T_SOCK" --timeout 60s)
fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the node's containerd runs, the helpers and its configuration are as setup left them, and its CRI answers..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || fail "the node's containerd is not running"
(cd "$STATE_DIR" && sha256sum patch_config.py mkimg.py lab.py verify.py kubelet-sim app.c pause.c | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
sha256sum "$ETC/containerd.toml" | awk '{print $1}' | cmp -s - "$STATE_DIR/containerd.toml.sha" || fail "containerd's configuration $ETC/containerd.toml is not as setup wrote it"
"${CRI[@]}" version >/dev/null 2>&1 || fail "the CRI of the node's containerd does not answer on $T_SOCK"
echo "  -> OK: containerd $(containerd --version | awk '{print $3}')"

echo "[precondition] containerd's runc uses the systemd cgroup driver (live configuration of its CRI plugin)..."
"${CRI[@]}" info 2>/dev/null | python3 -c '
import json, sys
c = json.load(sys.stdin)["config"]["containerd"]
d = c["defaultRuntimeName"]
assert d == "runc", "default runtime " + d
assert c["runtimes"][d]["options"]["SystemdCgroup"] is True, "SystemdCgroup is not true"
assert c["runtimes"]["runc-cgroupfs"]["options"]["SystemdCgroup"] is False, "the runc-cgroupfs handler is not as setup made it"
' || fail "containerd's default runtime is not runc with SystemdCgroup=true"
echo "  -> OK: default runtime runc, SystemdCgroup=true"

echo "[precondition] the kubelet is configured with the cgroupfs driver and talks to this containerd; no pod runs on the node..."
grep -qE '^cgroupDriver: cgroupfs$' "$ETC/kubelet-config.yaml" || fail "the kubelet configuration does not say cgroupDriver: cgroupfs"
grep -qE "^containerRuntimeEndpoint: unix://$T_SOCK\$" "$ETC/kubelet-config.yaml" || fail "the kubelet does not point at the node's containerd"
[ "$("${CRI[@]}" pods -q | grep -c .)" = 0 ] || fail "pods already exist on the node"
[ "$("${CRI[@]}" images | grep -c "$CASE_ID.local/")" = 3 ] || fail "the three images of the lab are not all there"
echo "  -> OK: cgroupDriver: cgroupfs, no pod"

echo "[precondition] the problem: the kubelet cannot start calico-node and kube-proxy, runc refuses the cgroup path, the node is NotReady..."
set +e
OUT=$(sudo "$LIB_BASE/bin/kubelet-sim" sync 2>&1)
RC=$?
set -e
[ "$RC" != 0 ] || fail "kubelet-sim sync succeeded: the node is not broken"
[ "$(echo "$OUT" | grep -c 'expected cgroupsPath to be of format')" = 2 ] || fail "the two pods do not both fail on the cgroup path (runc: expected cgroupsPath to be of format slice:prefix:name): $(echo "$OUT" | tail -3 | cut -c1-300)"
echo "$OUT" | grep -q 'node: Ready=False' || fail "the node is not NotReady"
[ "$("${CRI[@]}" pods -q | grep -c .)" = 0 ] || fail "the failed attempts left pods behind"
echo "  -> OK: both pods fail: $(echo "$OUT" | grep -oE 'for systemd cgroups, got \\"/kubepods/[a-z]+/pod[0-9a-f-]+' | head -1 | sed 's/\\//g')"

echo "[precondition] control: the same kind of pod runs when the cgroup parent and the runc cgroup driver agree (cgroupfs style on a cgroupfs runc)..."
python3 "$STATE_DIR/lab.py" control cgroupfs "$T_SOCK" "$WORK_DIR" || fail "a cgroupfs pod does not run on the cgroupfs handler: the host is not fit for the case"
echo "[precondition] control: and the systemd style cgroup parent on the node's default runtime (systemd driver)..."
python3 "$STATE_DIR/lab.py" control systemd "$T_SOCK" "$WORK_DIR" || fail "a pod with a systemd style cgroup parent does not run on the default runtime: the host is not fit for the case"
[ "$("${CRI[@]}" pods -q | grep -c .)" = 0 ] || fail "the controls left pods behind"

echo "[precondition] ALL CHECKS PASSED: containerd's runc uses the systemd driver, the kubelet the cgroupfs driver, so no pod of the node starts; a pod with a cgroup parent of the runc's own driver does."
