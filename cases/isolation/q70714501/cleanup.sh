#!/bin/bash
# 不加 set -e：teardown阶段允许部分命令因"本来就不存在"而失败

TESTUSER="testuser"
GROUP="crictl-users"
CONFIG="/etc/containerd/config.toml"

echo "[cleanup] resetting containerd config to defaults..."
containerd config default | sudo tee "$CONFIG" > /dev/null 2>&1 || true
sudo systemctl restart containerd 2>/dev/null || true
sleep 1

echo "[cleanup] removing test user..."
sudo userdel -r "$TESTUSER" 2>/dev/null || true

echo "[cleanup] removing dedicated group..."
sudo groupdel "$GROUP" 2>/dev/null || true

echo "[cleanup] removing crictl output artifacts..."
sudo rm -f /tmp/oracle_crictl_info.json /tmp/oracle_crictl_info.err

echo "[cleanup] done. Environment reset to clean state."
