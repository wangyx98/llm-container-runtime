#!/bin/bash
set -e

CASE_ID="bench56996594"
USER_NAME="$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
PORT=35996

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them, the registry serves the pinned image for its tag v1 and its digest, and the tag latest is another image..."
sudo bash -c 'cd "$1" && sha256sum marker.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
DIGEST=$(cat "$LIB_BASE/digest.txt")
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "digest.txt does not hold a digest"
[ "$(sudo grep -c '^GET /v2/bench56996594/marker/blobs' "$WORK_DIR/registry.log")" = 0 ] || fail "somebody pulled from the registry already"
echo "  -> OK: registry on 127.0.0.1:$PORT, pinned image $DIGEST"

echo "[precondition] the user $USER_NAME exists with its own range of subordinate IDs, without sudo and without a group of a rootful daemon, and has no way into the rootful sockets of the host..."
getent passwd "$USER_NAME" >/dev/null || fail "no user $USER_NAME"
USER_ID=$(id -u "$USER_NAME")
[ "$USER_ID" != 0 ] || fail "the user is root"
for f in /etc/subuid /etc/subgid; do
    awk -F: -v u="$USER_NAME" '$1==u && $3>=65536 {ok=1} END {exit !ok}' "$f" || fail "no range of at least 65536 subordinate IDs for $USER_NAME in $f"
done
for g in $(id -nG "$USER_NAME"); do
    case "$g" in docker|containerd|root|sudo|adm|wheel|lxd|podman|kvm) fail "the user is in the group $g";; esac
done
sudo -n -l -U "$USER_NAME" 2>&1 | grep -q "not allowed to run sudo" || fail "the user has sudo rights"
for s in /run/containerd/containerd.sock /run/docker.sock /var/run/docker.sock /run/podman/podman.sock; do
    if [ -S "$s" ] && sudo -n -u "$USER_NAME" sh -c 'test -r "$1" && test -w "$1"' sh "$s"; then fail "the user can open the rootful socket $s"; fi
done
echo "  -> OK: uid $USER_ID, subuid $(awk -F: -v u="$USER_NAME" '$1==u {print $2"+"$3; exit}' /etc/subuid), subgid $(awk -F: -v u="$USER_NAME" '$1==u {print $2"+"$3; exit}' /etc/subgid)"

echo "[precondition] nothing of the solution exists yet: no service, no daemon, no script, no containerd state of the user..."
[ -d "/run/user/$USER_ID" ] || fail "the user manager of $USER_NAME is not running (no /run/user/$USER_ID)"
sudo test ! -e "/home/$USER_NAME/.config/systemd/user/$CASE_ID-containerd.service" || fail "the unit exists already"
sudo test ! -e "/home/$USER_NAME/bin/run-marker.sh" || fail "run-marker.sh exists already"
[ -z "$(ps -u "$USER_NAME" -o comm= | grep -E '^(rootlesskit|containerd|containerd-shim)' || true)" ] || fail "a rootless daemon of the user runs already"
echo "  -> OK"

echo "[precondition] the control: rootlesskit gives the user a user namespace whose maps are '0 -> the user' and '1.. -> the subordinate range' (what the tools of the host are installed for)..."
MAP=$(sudo -n -u "$USER_NAME" -H env XDG_RUNTIME_DIR="/run/user/$USER_ID" timeout 60 rootlesskit sh -c 'cat /proc/self/uid_map; echo --; cat /proc/self/gid_map' 2>&1) || fail "rootlesskit does not start for the user: $(echo "$MAP" | tail -1 | cut -c1-200)"
SUB=$(awk -F: -v u="$USER_NAME" '$1==u {print $2; exit}' /etc/subuid)
SUBG=$(awk -F: -v u="$USER_NAME" '$1==u {print $2; exit}' /etc/subgid)
echo "$MAP" | awk -v uid="$USER_ID" -v gid="$(id -g "$USER_NAME")" -v su="$SUB" -v sg="$SUBG" '
    BEGIN {blk=0}
    /^--/ {blk=1; next}
    { own = blk ? gid : uid; lo = blk ? sg : su }
    $1==0 && $2==own && $3==1 {a[blk]=1}
    $1==1 && $2==lo && $3>=65536 {b[blk]=1}
    END {exit !(a[0] && b[0] && a[1] && b[1])}' \
    || fail "the maps rootlesskit made are not 0->the user and 1->the user's range: $(echo "$MAP" | tr -s ' \n' ' ' | cut -c1-120)"
echo "  -> OK: $(echo "$MAP" | sed -n 1,2p | tr -s ' \n' ' ')"

CTRL=$(cat "/sys/fs/cgroup/user.slice/user-$USER_ID.slice/user@$USER_ID.service/cgroup.controllers" 2>/dev/null || echo "unknown (no cgroup v2 user manager)")
echo "  -> info: controllers delegated to the user manager: $CTRL"

echo "[precondition] no container of the case runs in the rootful containerd either..."
if [ -S /run/containerd/containerd.sock ] && command -v ctr >/dev/null 2>&1; then
    [ -z "$(sudo timeout 20 ctr -n "$CASE_ID" containers ls -q 2>/dev/null)" ] || fail "a container of the case exists in the rootful containerd"
fi
echo "  -> OK"
