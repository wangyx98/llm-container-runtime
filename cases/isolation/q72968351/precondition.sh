#!/bin/bash
set -e

CASE_ID="bench72968351"
USER_NAME="$CASE_ID"
UNIT="$CASE_ID-k3s.service"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them and the record of the lab is complete (the seed image is in k8s.io, the decoy with the same name only in default)..."
sudo bash -c 'cd "$1" && sha256sum podmark.c mkimg.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] the user $USER_NAME has no sudo, no group of a rootful daemon and no way into the rootful sockets of the host..."
getent passwd "$USER_NAME" >/dev/null || fail "no user $USER_NAME"
USER_ID=$(id -u "$USER_NAME")
[ "$USER_ID" != 0 ] || fail "the user is root"
for g in $(id -nG "$USER_NAME"); do
    case "$g" in docker|containerd|root|sudo|adm|wheel|lxd|podman|kvm) fail "the user is in the group $g";; esac
done
sudo -n -l -U "$USER_NAME" 2>&1 | grep -q "not allowed to run sudo" || fail "the user has sudo rights"
for s in /run/containerd/containerd.sock /run/docker.sock /var/run/docker.sock /run/podman/podman.sock; do
    if [ -S "$s" ] && sudo -n -u "$USER_NAME" sh -c 'test -r "$1" && test -w "$1"' sh "$s"; then fail "the user can open the rootful socket $s"; fi
done
echo "  -> OK: uid $USER_ID"

echo "[precondition] the runner: the service is active, its containerd runs as the user in a mount namespace of its own, and nothing named k3s exists on the host's file system..."
RT="/run/user/$USER_ID"
as_user() { sudo -n -u "$USER_NAME" -H env XDG_RUNTIME_DIR="$RT" DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@"; }
[ "$(as_user systemctl --user is-active "$UNIT" 2>/dev/null)" = active ] || fail "the user service $UNIT is not active"
CP=$(sudo cat "$RT/$CASE_ID-rootlesskit/child_pid" 2>/dev/null) || fail "no child_pid of rootlesskit"
[ "$(sudo awk '/^Uid:/ {print $2}' /proc/$CP/status)" = "$USER_ID" ] || fail "rootlesskit's child is not a process of the user"
[ "$(sudo readlink /proc/$CP/ns/mnt)" != "$(readlink /proc/self/ns/mnt)" ] || fail "rootlesskit's child is in the mount namespace of the host"
CD=""
for p in $(pgrep -u "$USER_NAME" -x containerd); do [ "$(sudo readlink /proc/$p/ns/mnt)" = "$(sudo readlink /proc/$CP/ns/mnt)" ] && CD=$p && break; done
[ -n "$CD" ] || fail "no containerd of the user runs in the mount namespace of rootlesskit's child"
[ -z "$(find /run /var/run /usr/local/bin /etc -maxdepth 2 -name '*k3s*' 2>/dev/null)" ] || fail "something named k3s exists on the host: $(find /run /var/run /usr/local/bin /etc -maxdepth 2 -name '*k3s*' 2>/dev/null | head -1)"
echo "  -> OK: containerd is process $CD of the user (rootlesskit child $CP), in mount namespace $(sudo readlink /proc/$CP/ns/mnt)"

echo "[precondition] the symptom: the ctr of the host, as the user, with the endpoint of the K3s book (/run/k3s/containerd/containerd.sock) and with the default one..."
OUT=$(as_user timeout 30 ctr --address /run/k3s/containerd/containerd.sock --timeout 5s -n k8s.io images ls 2>&1) && fail "ctr of the host reached a containerd through /run/k3s/containerd/containerd.sock" || true
echo "  -> $(echo "$OUT" | tail -1 | cut -c1-160)"
OUT=$(as_user timeout 30 ctr --timeout 5s -n k8s.io images ls 2>&1) && fail "the default endpoint of ctr gives the user a containerd" || true
echo "  -> $(echo "$OUT" | tail -1 | cut -c1-160)"
[ ! -e /run/k3s ] || fail "/run/k3s exists on the host"

echo "[precondition] nothing of the solution exists yet: no wrapper in the user's bin..."
sudo test ! -e "/home/$USER_NAME/bin/ctr-k3s" || fail "ctr-k3s exists already"
sudo test ! -e "/home/$USER_NAME/bin/crictl-k3s" || fail "crictl-k3s exists already"
echo "  -> OK"

echo "[precondition] the control: through the way in that the lab uses (nsenter as the user into the namespaces of rootlesskit's child) an image is imported into k8s.io and a Pod runs from it..."
CTRL=$(cat "/sys/fs/cgroup/user.slice/user-$USER_ID.slice/user@$USER_ID.service/cgroup.controllers" 2>/dev/null || echo "unknown (no cgroup v2 user manager)")
echo "  -> info: controllers delegated to the user manager: $CTRL"
sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "no Pod runs in the runner (see above)"
