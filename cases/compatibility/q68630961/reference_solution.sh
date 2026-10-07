#!/bin/bash
set -e

# The release tarball only holds binaries: systemd has no unit for them, so it answers "Unit not
# found". Write the unit (the same shape as containerd's own containerd.service, pointed at the
# tarball's binary and at the prepared config), tell systemd, and enable it for the next boot and
# start it now.
sudo tee /etc/systemd/system/bench68630961-containerd.service >/dev/null <<'UNITEOF'
[Unit]
Description=containerd container runtime (bench68630961, installed from the release tarball)
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
Type=notify
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/opt/bench68630961/bin/containerd --config /opt/bench68630961/etc/config.toml
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable --now bench68630961-containerd.service
