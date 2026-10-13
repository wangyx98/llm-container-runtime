#!/bin/bash
set -e

CASE_ID="bench72968351"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"          # the oracle's own record (root only)
USER_NAME="$CASE_ID"                  # the user whose rootless K3s-like runner exists
DROPIN_DIR="/etc/systemd/system/user@.service.d"
UNIT="$CASE_ID-k3s.service"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[setup] checking the tools of a rootless setup: rootlesskit, newuidmap/newgidmap, containerd, ctr, crictl, runc, nsenter, systemctl, loginctl..."
need_rootless_pkgs=0
for c in rootlesskit newuidmap newgidmap; do command -v "$c" >/dev/null || need_rootless_pkgs=1; done
if [ "$need_rootless_pkgs" = 1 ]; then
    # rootlesskit and newuidmap/newgidmap are what the runner is built on, not the thing under test: install them like gcc below
    echo "[setup] rootlesskit and/or uidmap are not installed; installing the Ubuntu packages rootlesskit and uidmap..."
    sudo -E apt-get update -qq || true
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" rootlesskit uidmap || true
fi
for c in rootlesskit newuidmap newgidmap containerd ctr crictl runc nsenter systemctl loginctl python3 sudo; do
    command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found (rootlesskit and uidmap: sudo apt-get install -y rootlesskit uidmap; crictl and runc come with the cri-tools / runc / containerd packages)"; exit 1; }
done
for c in newuidmap newgidmap; do
    p=$(command -v "$c")
    [ -u "$p" ] || getcap "$p" 2>/dev/null | grep -q cap_set || { echo "[setup] ERROR: $p is neither set-uid nor has file capabilities: a user cannot get a range of IDs"; exit 1; }
done
containerd --version | head -1
rootlesskit --version | head -1
crictl --version | head -1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] making sure gcc is available (one tiny static program, so nothing has to be pulled)..."
if ! command -v gcc >/dev/null 2>&1; then
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq "${APT_OPTS[@]}" gcc libc6-dev
fi

if [ -d /run/systemd/system ]; then
    echo "[setup] the prerequisite of every rootless K3s: cgroup v2 controllers cpu, cpuset, io, memory, pids delegated to the users' systemd instances (the Pods' cgroups need them)..."
    sudo install -d -m 755 "$DROPIN_DIR"
    printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee "$DROPIN_DIR/$CASE_ID-delegate.conf" >/dev/null
    sudo systemctl daemon-reload
fi

echo "[setup] the user $USER_NAME: no sudo, no group of a rootful daemon, a range of subordinate IDs, a systemd user manager that keeps running (lingering)..."
sudo useradd --create-home --shell /bin/bash --user-group "$USER_NAME"
grep -q "^$USER_NAME:" /etc/subuid || sudo usermod --add-subuids 700000-765535 "$USER_NAME"
grep -q "^$USER_NAME:" /etc/subgid || sudo usermod --add-subgids 700000-765535 "$USER_NAME"
USER_ID=$(id -u "$USER_NAME")
H="/home/$USER_NAME"
RT="/run/user/$USER_ID"
sudo loginctl enable-linger "$USER_NAME"
for _ in $(seq 1 60); do
    [ -d "$RT" ] && { [ ! -d /run/systemd/system ] || [ -S "$RT/bus" ] || [ -S "$RT/systemd/private" ]; } && break
    sleep 0.5
done
[ -d "$RT" ] || { echo "[setup] ERROR: no $RT: the user manager of $USER_NAME did not start"; exit 1; }
as_user() { sudo -u "$USER_NAME" -H env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@"; }

echo "[setup] resetting the work dir and copying the helpers..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 755 "$WORK_DIR"
sudo install -d -m 700 -o root -g root "$STATE_DIR"
sudo cp "$CASE_DIR"/helpers/{podmark.c,mkimg.py,lab.py,verify.py} "$STATE_DIR/"
sudo bash -c 'cd "$1" && sha256sum podmark.c mkimg.py lab.py verify.py | awk "{print \$1}" > helpers.sha' _ "$STATE_DIR"
sudo gcc -static -O2 -o "$STATE_DIR/podmark" "$STATE_DIR/podmark.c"
install -d -m 1777 "$WORK_DIR/out"          # archives and Pod files of the lab and of the oracle's runs; the user has to be able to write there
cd "$WORK_DIR"

echo "[setup] the runner: containerd with the CRI plugin as a systemd USER service, rootlesskit around it (a K3s-like layout: socket and state in /run, images in the CRI's namespace k8s.io)..."
TOKEN=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')       # the socket's directory differs per setup: no path from a book or from the question works
SOCK_DIR="/run/k3s-$TOKEN/containerd"
as_user mkdir -p "$H/bin" "$H/k3s/containerd/root" "$H/k3s/cni/bin" "$H/k3s/cni/net.d" "$H/.config/systemd/user"

as_user tee "$H/k3s/containerd/config.toml" >/dev/null <<CFG
version = 3
root = "$H/k3s/containerd/root"
state = "$SOCK_DIR"
disabled_plugins = ["io.containerd.nri.v1.nri"]

[grpc]
  address = "$SOCK_DIR/containerd.sock"

[plugins.'io.containerd.cri.v1.runtime']
  disable_apparmor = true
  restrict_oom_score_adj = true
  enable_unprivileged_ports = false
  enable_unprivileged_icmp = false
  enable_cdi = false

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dirs = ['$H/k3s/cni/bin']
  conf_dir = '$H/k3s/cni/net.d'

[plugins.'io.containerd.cri.v1.images'.pinned_images]
  sandbox = 'bench72968351.test/pause:1'
CFG

# a stand-in for flannel: the Pods need a network namespace of their own and a CNI result, not a network (a rootless runner has no way to set one up without more tools)
as_user tee "$H/k3s/cni/net.d/10-bench.conflist" >/dev/null <<'CNI'
{"cniVersion":"1.0.0","name":"benchnet","plugins":[{"type":"benchcni"}]}
CNI
as_user tee "$H/k3s/cni/bin/benchcni" >/dev/null <<'CNI'
#!/bin/sh
# stub CNI plugin (installed as "benchcni" and "loopback"): the lab's Pods need a network namespace of their own, nothing more
case "$CNI_COMMAND" in
ADD)
  command -v ip >/dev/null 2>&1 && nsenter --net="$CNI_NETNS" ip link set lo up >&2
  if [ "$(basename "$0")" = loopback ]; then
    printf '{"cniVersion":"1.0.0","interfaces":[{"name":"lo","sandbox":"%s"}],"ips":[{"address":"127.0.0.1/8","interface":0}]}\n' "$CNI_NETNS"
  else
    printf '{"cniVersion":"1.0.0","interfaces":[{"name":"eth0","sandbox":"%s"}],"ips":[{"address":"10.72.0.2/24","interface":0}]}\n' "$CNI_NETNS"
  fi ;;
DEL|CHECK|GC) : ;;
VERSION) echo '{"cniVersion":"1.0.0","supportedVersions":["0.3.0","0.3.1","0.4.0","1.0.0"]}' ;;
esac
exit 0
CNI
as_user chmod +x "$H/k3s/cni/bin/benchcni"
as_user ln -sf benchcni "$H/k3s/cni/bin/loopback"

# rootlesskit makes the user namespace (0 -> the user, 1.. -> the subordinate range) and copies up /etc, /run and /var/lib so containerd can write there; what copy-up links to the
# host's root-owned directories (/run/containerd, /run/netns, /var/lib/cni) has to go. The socket lives in THIS mount namespace only.
as_user tee "$H/bin/start-k3s.sh" >/dev/null <<SCRIPT
#!/bin/sh
exec rootlesskit --state-dir="\$XDG_RUNTIME_DIR/$CASE_ID-rootlesskit" --net=host --copy-up=/etc --copy-up=/run --copy-up=/var/lib --propagation=rslave \\
    sh -c 'rm -f /run/containerd /run/netns /var/lib/cni; mkdir -p $SOCK_DIR /run/netns /var/lib/cni; exec containerd --config $H/k3s/containerd/config.toml'
SCRIPT
as_user chmod +x "$H/bin/start-k3s.sh"

as_user tee "$H/.config/systemd/user/$UNIT" >/dev/null <<UNIT
[Unit]
Description=rootless K3s-like runner (containerd + CRI) of $USER_NAME

[Service]
Type=simple
Delegate=yes
ExecStart=$H/bin/start-k3s.sh
Restart=on-failure

[Install]
WantedBy=default.target
UNIT

as_user systemctl --user daemon-reload
as_user systemctl --user enable --now "$UNIT"

echo "[setup] the pause image and the seed image into k8s.io, a decoy with the same name into the namespace default, and the record of what is true..."
sudo python3 "$STATE_DIR/lab.py" up "$WORK_DIR" || { echo "[setup] ERROR: the runner did not come up or the images were not imported"; as_user systemctl --user status "$UNIT" 2>&1 | tail -5; exit 1; }

echo "[setup] done. User $USER_NAME (uid $USER_ID) runs the rootless runner $UNIT; its containerd socket is not on the host's file system. No ctr/crictl wrapper exists."
