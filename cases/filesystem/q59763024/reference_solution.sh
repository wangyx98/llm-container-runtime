#!/bin/bash
set -e

DEPLOY=/var/lib/bench59763024/deploy
FIX=/var/lib/bench59763024/fix
BIN=/tmp/bench59763024/bin
IMG=localhost/bench59763024/controller:1

echo "[solution] two causes: (1) /etc/ingress-controller/ssl in the image belongs to uid 33 (mode 775) and the controller runs as 101: give it the group 33; (2) the image's /bin/busybox has no file capability, so a non-root process gets no NET_BIND_SERVICE from the capability sets alone: put a copy of the same program (the machine's busybox, the one the image was made from) with the file capability over it"
$BIN/node-crictl logs "$($BIN/node-crictl ps -a -q | head -1)" 2>&1 | tail -2
sudo mkdir -p "$FIX"
sudo cp "$(command -v busybox)" "$FIX/busybox"        # the image's program was made from this very file
sudo chmod 755 "$FIX/busybox"
sudo python3 -c 'import os; os.setxattr("/var/lib/bench59763024/fix/busybox", "security.capability", b"\x01\x00\x00\x02\x00\x04\x00\x00" + b"\x00" * 12)'   # cap_net_bind_service=+ep

sudo python3 - <<'PYEOF'
import json
p = "/var/lib/bench59763024/deploy/controller.json"
c = json.load(open(p))
c["linux"]["security_context"]["supplemental_groups"] = [33]
c["mounts"] = [{"container_path": "/bin/busybox", "host_path": "/var/lib/bench59763024/fix/busybox", "readonly": True}]
json.dump(c, open(p, "w"), indent=1)
PYEOF
echo "[solution] apply the deployment"
$BIN/node-apply
sleep 1
curl -s http://127.0.0.1/healthz; curl -s http://127.0.0.1/fake-certificate | head -2
