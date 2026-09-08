#!/bin/bash
set -e

CRIO_DROPIN_DIR="/etc/crio/crio.conf.d"
BROKEN_PROFILE_PATH="/etc/crio/broken-seccomp.json"
POD_CONFIG="/tmp/bench61058619_pod.json"
CONTAINER_CONFIG="/tmp/bench61058619_container.json"
IMAGE="docker.io/library/busybox:latest"

echo "[setup] checking CRI-O is installed..."
if ! command -v crio >/dev/null 2>&1; then
    echo "[setup] ERROR: crio not found. Install CRI-O first (see task.txt notes)."
    exit 1
fi

echo "[setup] ensuring CRI-O's GLOBAL config is clean/default (daemon must stay healthy)..."
sudo rm -f "$CRIO_DROPIN_DIR/99-broken-seccomp.conf"
sudo mkdir -p "$CRIO_DROPIN_DIR"
sudo systemctl restart crio
sleep 2

if ! sudo systemctl is-active --quiet crio; then
    echo "[setup] ERROR: crio failed to start even with a clean config. Check 'journalctl -u crio'."
    exit 1
fi
echo "[setup] crio daemon is healthy."

echo "[setup] pointing crictl at the CRI-O socket..."
{
    echo "runtime-endpoint: unix:///var/run/crio/crio.sock"
    echo "image-endpoint: unix:///var/run/crio/crio.sock"
    echo "timeout: 5"
    echo "debug: false"
} | sudo tee /etc/crictl.yaml > /dev/null

echo "[setup] pulling a small test image ($IMAGE)..."
sudo crictl pull "$IMAGE"

echo "[setup] writing a BROKEN seccomp profile (invalid JSON content)..."
sudo tee "$BROKEN_PROFILE_PATH" > /dev/null <<'EOF'
{ this is not valid seccomp profile json at all !!! }
EOF

echo "[setup] writing pod sandbox config (host network, no seccomp issues at THIS level)..."
sudo tee "$POD_CONFIG" > /dev/null <<'EOF'
{
  "metadata": {
    "name": "bench61058619",
    "namespace": "default",
    "attempt": 1,
    "uid": "bench61058619-uid"
  },
  "log_directory": "/tmp/bench61058619-logs",
  "linux": {
    "security_context": {
      "namespace_options": {
        "network": 2
      }
    }
  }
}
EOF
sudo mkdir -p /tmp/bench61058619-logs

echo "[setup] writing CONTAINER config that references the broken profile via its OWN security_context..."
sudo tee "$CONTAINER_CONFIG" > /dev/null <<EOF
{
  "metadata": {
    "name": "bench61058619-ctr"
  },
  "image": {
    "image": "$IMAGE"
  },
  "command": ["sleep", "3600"],
  "linux": {
    "security_context": {
      "seccomp": {
        "profile_type": 2,
        "localhost_ref": "$BROKEN_PROFILE_PATH"
      }
    }
  },
  "log_path": "container.log"
}
EOF

echo "[setup] starting the (always-healthy) pod sandbox..."
POD_ID=$(sudo crictl runp "$POD_CONFIG")
echo "$POD_ID" | sudo tee /tmp/bench61058619_podid.txt > /dev/null

echo "[setup] done. Pod sandbox is Ready. Container creation will fail due to the broken profile."
sudo crictl pods --id "$POD_ID"
