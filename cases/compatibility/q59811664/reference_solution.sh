#!/bin/bash
set -e

W="/tmp/bench59811664"
WS="sudo podman --root $W/workstation/root --runroot $W/workstation/run"
REG=$(cat $W/registry.addr)

echo "[solution] the registry speaks plain HTTP: push with TLS verification off..."
$WS push --tls-verify=false localhost/bench59811664/app:v1 docker://$REG/bench59811664/app:v1

echo "[solution] CRI-O needs the same exception: an insecure-registry setting, then a reload (it reads"
echo "[solution] registries.conf.d at start and on SIGHUP only)..."
sudo mkdir -p /etc/containers/registries.conf.d
printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$REG" | sudo tee /etc/containers/registries.conf.d/99-bench59811664.conf >/dev/null
sudo kill -HUP "$(pgrep -x crio)"
sleep 1

echo "[solution] CRI-O pulls it from the registry (same image id as the workstation's):"
sudo crictl pull $REG/bench59811664/app:v1

cat > $W/pod-config.json <<JSON
{"metadata": {"name": "bench59811664-pod", "namespace": "default", "attempt": 1, "uid": "bench59811664uid00000001"},
 "log_directory": "$W", "linux": {}}
JSON
cat > $W/container-config.json <<JSON
{"metadata": {"name": "bench59811664"}, "image": {"image": "$REG/bench59811664/app:v1"},
 "log_path": "bench59811664.0.log", "linux": {}}
JSON
POD_ID=$(sudo crictl runp $W/pod-config.json)
CTR_ID=$(sudo crictl create "$POD_ID" $W/container-config.json $W/pod-config.json)
sudo crictl start "$CTR_ID"
