#!/bin/bash
set -e

CASE_ID="bench60208766"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
ETC="/etc/$CASE_ID"
UNIT="$CASE_ID-containerd.service"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them and the lab is as its record says (binaries, unit, configuration, CNI files, images, the API, the registry and the proxy processes)..."
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py proxy.py api.py alias.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] the service runs the lab's containerd 2.0.0 with the real Calico plugin (one binary under two names, the pinned release) and the kubeconfig names the API Service address..."
[ "$(sudo systemctl is-active "$UNIT")" = active ] || fail "$UNIT is not active"
sudo test -S "/run/$CASE_ID/containerd.sock" || fail "no CRI socket"
sudo "/var/lib/$CASE_ID/bin/containerd" --version | head -1
[ "$(sudo sha256sum < "/var/lib/$CASE_ID/cni/bin/calico")" = "$(sudo sha256sum < "/var/lib/$CASE_ID/cni/bin/calico-ipam")" ] || fail "calico and calico-ipam are not the same release binary"
sudo grep -q 'server: https://10.96.0.1:443' "$ETC/cni/calico-kubeconfig" || fail "the kubeconfig of the plugin does not name https://10.96.0.1:443"
sudo grep -q '"type": "calico"' "$ETC/cni/net.d/10-calico.conf" || fail "the CNI configuration is not Calico's"
echo "  -> OK: Calico $(sudo sha256sum < "/var/lib/$CASE_ID/cni/bin/calico" | cut -c1-12), API https://10.96.0.1:443"

echo "[precondition] nothing of the solution exists yet: the node's proxy settings are the drop-in of the lab and do not name 10.96.0.1, no environment file, no other drop-in..."
[ "$(ls "/etc/systemd/system/$UNIT.d")" = "http-proxy.conf" ] || fail "the drop-in directory has other files than http-proxy.conf"
! sudo grep -q '10\.96' "/etc/systemd/system/$UNIT.d/http-proxy.conf" || fail "the drop-in names the API address already"
[ ! -e "/etc/default/$CASE_ID-containerd" ] || fail "/etc/default/$CASE_ID-containerd exists already"
! sudo systemctl show -p Environment --value "$UNIT" | grep -q '10\.96' || fail "the service environment names the API address already"
echo "  -> OK: $(sudo systemctl show -p Environment --value "$UNIT" | tr ' ' '\n' | grep -i proxy | tr '\n' ' ')"

echo "[precondition] the symptom and the controls: the proxy settings are in the service, the API answers directly and not through the proxy, a cold pull works through the proxy and not around it, a new Pod sandbox fails with the 301 error and the proxy log shows the CONNECT to 10.96.0.1:443, the real plugin run by hand works with NO_PROXY naming 10.96.0.1..."
sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "see above"
