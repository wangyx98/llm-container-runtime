#!/bin/bash
# Reference: a rootless containerd (rootlesskit) as a systemd USER service of bench56996594, the pinned image pulled from the lab's registry by digest, and the script
# /home/bench56996594/bin/run-marker.sh NONCE OUTFILE that runs the program of the image in it. No rootful socket is touched; sudo is only used to become that user.
set -e

U=bench56996594
H=/home/$U
UID_U=$(id -u $U)
RT=/run/user/$UID_U
DIGEST=$(cat /var/lib/bench56996594/digest.txt)
IMG=127.0.0.1:35996/bench56996594/marker@$DIGEST

as_user() { sudo -u $U -H env XDG_RUNTIME_DIR=$RT DBUS_SESSION_BUS_ADDRESS=unix:path=$RT/bus "$@"; }

as_user mkdir -p $H/bin $H/containerd/root $H/.config/systemd/user

# containerd for a user: everything below the user's home, the CRI and NRI services off (they want root-owned directories), the socket in the home
as_user tee $H/containerd/config.toml >/dev/null <<CFG
version = 3
root = "$H/containerd/root"
state = "/run/containerd"
disabled_plugins = ["io.containerd.grpc.v1.cri", "io.containerd.nri.v1.nri"]

[grpc]
  address = "$H/containerd/containerd.sock"
CFG

# rootlesskit makes the user namespace (0 -> the user, 1.. -> the subordinate range of /etc/subuid and /etc/subgid) and copies up /etc and /run so containerd can write there;
# the symlinks that copy-up makes for what exists on the host (/run/containerd of the rootful daemon) have to go
as_user tee $H/bin/start-containerd.sh >/dev/null <<'SCRIPT'
#!/bin/sh
exec rootlesskit --state-dir="$XDG_RUNTIME_DIR/bench56996594-rootlesskit" --net=host --copy-up=/etc --copy-up=/run --propagation=rslave \
    sh -c 'rm -f /run/containerd; exec containerd --config /home/bench56996594/containerd/config.toml'
SCRIPT
as_user chmod +x $H/bin/start-containerd.sh

as_user tee $H/.config/systemd/user/$U-containerd.service >/dev/null <<UNIT
[Unit]
Description=rootless containerd of $U

[Service]
Type=simple
Delegate=yes
ExecStart=$H/bin/start-containerd.sh
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

# ctr has to run in the namespaces of rootlesskit's child (its /run is the one containerd and the shims use)
as_user tee $H/bin/ctr-rootless.sh >/dev/null <<'SCRIPT'
#!/bin/sh
RT=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
exec nsenter -U --preserve-credentials -m -t "$(cat "$RT/bench56996594-rootlesskit/child_pid")" ctr --address /home/bench56996594/containerd/containerd.sock "$@"
SCRIPT
as_user chmod +x $H/bin/ctr-rootless.sh

as_user systemctl --user daemon-reload
as_user systemctl --user enable --now $U-containerd.service

echo "waiting for the containerd of the user..."
for _ in $(seq 1 60); do
    as_user $H/bin/ctr-rootless.sh version >/dev/null 2>&1 && break
    sleep 0.5
done

as_user $H/bin/ctr-rootless.sh images pull --plain-http "$IMG" >/dev/null

# the script the check runs: the container has its own cgroup below the user's delegated one (a relative path), --rm removes it; the program's output goes to OUTFILE.
# ctr run asks for cpu.shares 1024 by default (runc turns it into cpu.weight): --cpu-shares 0 leaves it out, because the cpu controller is not delegated to a user by default.
as_user tee $H/bin/run-marker.sh >/dev/null <<SCRIPT
#!/bin/bash
set -e
NONCE=\$1
OUT=\$2
exec $H/bin/ctr-rootless.sh run --rm --cgroup "marker-\$\$" --cpu-shares 0 "$IMG" "marker-\$\$" /marker "\$NONCE" > "\$OUT"
SCRIPT
as_user chmod +x $H/bin/run-marker.sh

as_user systemctl --user is-active $U-containerd.service
echo "done: $H/bin/run-marker.sh NONCE OUTFILE runs $DIGEST as $U, rootless"
