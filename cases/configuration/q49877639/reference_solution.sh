#!/bin/bash
set -e
# Reference solution. systemd mounts a tmpfs on /run, which hides /run/docker/plugins (where the plugin's socket must appear); Docker adds its own /sys/fs/cgroup mount after the
# mounts of config.json, so a read-only (or any) mount there does not give systemd the cgroups it needs. An init script keeps the socket directory and rebinds the host's cgroups
# before it starts systemd; the unit creates the socket in the kept directory.
D="docker -H unix:///run/bench49877639/docker.sock"
SRC=/var/lib/bench49877639/plugin

sudo $D plugin rm -f bench/sysd:1

sudo tee $SRC/rootfs/init >/dev/null <<'INIT'
#!/bin/sh
mkdir -p /dockerplugins
mount --bind /run/docker/plugins /dockerplugins
mount --rbind /hostcgroup /sys/fs/cgroup
exec /usr/lib/systemd/systemd
INIT
sudo chmod 755 $SRC/rootfs/init
sudo sed -i 's#/run/docker/plugins/sysd.sock#/dockerplugins/sysd.sock#' $SRC/rootfs/etc/systemd/system/plugin.service
sudo python3 - <<'PY'
import json
p = "/var/lib/bench49877639/plugin/config.json"
c = json.load(open(p))
c["entrypoint"] = ["/init"]
c["mounts"] = [{"destination": "/hostcgroup", "source": "/sys/fs/cgroup", "type": "bind", "options": ["rbind", "rw", "rprivate"]}]
json.dump(c, open(p, "w"), indent=2)
PY

sudo $D plugin create bench/sysd:1 $SRC
sudo $D plugin enable bench/sysd:1
