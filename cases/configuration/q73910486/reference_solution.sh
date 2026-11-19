#!/bin/bash
set -e

W="/tmp/bench73910486"
CONF="/var/lib/bench73910486/etc/containerd.toml"
ACCOUNT="/var/lib/bench73910486/registry/account"
REGLOG="/var/lib/bench73910486/registry/requests.log"

# Who gives the account? Not crictl (no --creds, no crictl.yaml entry) and not the hosts.toml: the registry's log shows containerd itself answering the 401
echo "[solution] the registry's log: the last requests of containerd (401 without an account, then 200 with one):"
sudo grep 'ua=containerd' "$REGLOG" | tail -n 2 | cut -c1-140
echo "[solution] the credentials are in containerd's own configuration:"
sudo grep -nE 'registry\.configs|username|password' "$CONF" | sed 's/password = .*/password = .../'

# remove the static credential of the registry (the table registry.configs."<host>".auth) and restart containerd, which reads its configuration only at start
sudo python3 - "$CONF" <<'PY'
import re, sys
p = sys.argv[1]
out, skip = [], False
for line in open(p).read().splitlines(keepends=True):
    if re.match(r'^\s*\[', line):
        skip = bool(re.match(r'^\s*\[plugins\."io\.containerd\.cri\.v1\.images"\.registry\.configs\.[^\]]*\.auth\]', line))
    if not skip:
        out.append(line)
open(p, "w").write("".join(out))
PY
sudo /var/lib/bench73910486/bin/containerdctl restart

HOST=$(sudo sed -n 's/^server = "http:\/\/\(.*\)"/\1/p' /var/lib/bench73910486/etc/certs.d/*/hosts.toml | head -1)
IMG="$HOST/bench73910486/hello-world:latest"
echo "[solution] without credentials the pull is refused now:"
"$W/bin/node-crictl" pull "$IMG" 2>&1 | tail -1 | cut -c1-200 || true
echo "[solution] with the account given explicitly it works:"
"$W/bin/node-crictl" pull --creds "$(sudo cat "$ACCOUNT")" "$IMG" | tail -1
"$W/bin/node-crictl" rmi "$IMG" >/dev/null
