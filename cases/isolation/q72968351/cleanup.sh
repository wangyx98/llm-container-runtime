#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench72968351"
USER_NAME="$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
DROPIN_DIR="/etc/systemd/system/user@.service.d"

echo "[cleanup] stopping the user's service and processes (the user manager, rootlesskit, containerd, shims, the Pods' programs)..."
if getent passwd "$USER_NAME" >/dev/null; then
    USER_ID=$(id -u "$USER_NAME")
    if [ -d "/run/user/$USER_ID" ]; then
        sudo -n -u "$USER_NAME" -H env XDG_RUNTIME_DIR="/run/user/$USER_ID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
            timeout 30 systemctl --user disable --now "$CASE_ID-k3s.service" >/dev/null 2>&1 || true
    fi
    sudo loginctl disable-linger "$USER_NAME" >/dev/null 2>&1 || true
    sudo loginctl terminate-user "$USER_NAME" >/dev/null 2>&1 || true
    sudo pkill -KILL -u "$USER_NAME" >/dev/null 2>&1 || true
    # what ran in the user's namespaces with another ID of the user's range (subordinate IDs) is not found by the name of the user
    range=$(awk -F: -v u="$USER_NAME" '$1==u {print $2" "$3}' /etc/subuid)
    if [ -n "$range" ]; then
        set -- $range
        ps -eo pid=,uid= | awk -v lo="$1" -v hi="$(( $1 + $2 ))" '$2 >= lo && $2 < hi {print $1}' | xargs -r sudo kill -9 2>/dev/null
    fi
    for _ in $(seq 1 20); do pgrep -u "$USER_NAME" >/dev/null 2>&1 || break; sleep 0.5; done
fi

echo "[cleanup] what a solution may have left on the host: a sudoers rule, a link to the runner's socket, a probe in the rootful containerd..."
sudo rm -f "/etc/sudoers.d/$CASE_ID" "/etc/sudoers.d/$CASE_ID"-*
for l in /run/k3s* /var/run/k3s* /usr/local/bin/*k3s*; do
    [ -L "$l" ] && readlink "$l" | grep -q -e '^/proc/' -e "$CASE_ID" && sudo rm -f "$l"
done
if [ -S /run/containerd/containerd.sock ] && command -v ctr >/dev/null 2>&1; then
    for ns in k8s.io "$CASE_ID"; do
        for i in $(sudo timeout 20 ctr -n "$ns" images ls -q 2>/dev/null | grep -e 'bench72968351\.test'); do sudo timeout 20 ctr -n "$ns" images rm "$i" >/dev/null 2>&1 || true; done
    done
    for c in $(sudo timeout 20 ctr -n "$CASE_ID" containers ls -q 2>/dev/null); do
        sudo timeout 20 ctr -n "$CASE_ID" tasks kill -s KILL "$c" >/dev/null 2>&1 || true
        sudo timeout 20 ctr -n "$CASE_ID" tasks delete "$c" >/dev/null 2>&1 || true
        sudo timeout 20 ctr -n "$CASE_ID" containers delete "$c" >/dev/null 2>&1 || true
    done
    sudo timeout 20 ctr namespaces remove "$CASE_ID" >/dev/null 2>&1 || true
fi
sleep 0.5

echo "[cleanup] removing the user, its home and ranges of IDs, the cgroup directories that are left, the delegation drop-in and the work dir..."
if getent passwd "$USER_NAME" >/dev/null; then
    sudo userdel -r "$USER_NAME" >/dev/null 2>&1 || { sleep 2; sudo pkill -KILL -u "$USER_NAME" >/dev/null 2>&1; sudo userdel -r -f "$USER_NAME" >/dev/null 2>&1; }
fi
getent group "$USER_NAME" >/dev/null && sudo groupdel "$USER_NAME" >/dev/null 2>&1
grep -q "^$USER_NAME:" /etc/subuid 2>/dev/null && sudo sed -i "/^$USER_NAME:/d" /etc/subuid
grep -q "^$USER_NAME:" /etc/subgid 2>/dev/null && sudo sed -i "/^$USER_NAME:/d" /etc/subgid
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -name "$CASE_ID*" -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 9 -type d -name "$CASE_ID*" 2>/dev/null | grep -q . || break
    sleep 1
done
if [ -e "$DROPIN_DIR/$CASE_ID-delegate.conf" ]; then
    sudo rm -f "$DROPIN_DIR/$CASE_ID-delegate.conf"
    sudo rmdir "$DROPIN_DIR" 2>/dev/null
    sudo systemctl daemon-reload >/dev/null 2>&1
fi
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-* "/tmp/$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
