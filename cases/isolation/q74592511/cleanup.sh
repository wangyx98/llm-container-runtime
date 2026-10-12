#!/bin/bash
# no set -e: a teardown may fail on things that are not there

CASE_ID="bench74592511"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
CONFIG="/etc/containerd/config.toml"
CRICTL_CONF="/etc/crictl.yaml"
DEV="bench74592511-dev"
OTHER="bench74592511-other"

restart_containerd() {   # systemd refuses a 6th start within 10 s: reset the counter and try again
    sudo systemctl restart containerd 2>/dev/null && return 0
    sudo systemctl reset-failed containerd 2>/dev/null; sleep 8
    sudo systemctl restart containerd
}

echo "[cleanup] stopping relay processes of the case (found by their command line)..."
for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$$" ] && continue
    if sudo tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q "$CASE_ID-proxy"; then
        sudo kill -9 "$p" 2>/dev/null
    fi
done
sudo rm -f /tmp/$CASE_ID-* /run/$CASE_ID-proxy*

echo "[cleanup] removing the probe images the oracle imported..."
if command -v ctr >/dev/null 2>&1; then
    timeout 30 sudo ctr -n k8s.io images ls -q 2>/dev/null | grep "$CASE_ID" | while read -r ref; do
        timeout 30 sudo ctr -n k8s.io images rm "$ref" >/dev/null 2>&1
    done
fi

echo "[cleanup] removing the users, the groups created during the run, and sudo rules naming the users..."
sudo userdel -r "$DEV" 2>/dev/null
sudo userdel -r "$OTHER" 2>/dev/null
if sudo test -f "$LIB_BASE/groups.before"; then
    BEFORE=$(sudo cat "$LIB_BASE/groups.before")
    for g in $(getent group | awk -F: '$3>=1000 && $3<60000 {print $1}'); do
        echo "$BEFORE" | grep -qx "$g" || sudo groupdel "$g" 2>/dev/null
    done
fi
for f in $(sudo ls /etc/sudoers.d 2>/dev/null); do
    sudo grep -q "$CASE_ID" "/etc/sudoers.d/$f" 2>/dev/null && sudo rm -f "/etc/sudoers.d/$f"
done

echo "[cleanup] removing a stand-in crictl that carries the case's name..."
for f in /usr/local/sbin/crictl /usr/local/bin/crictl /usr/sbin/crictl; do
    [ -f "$f" ] && sudo grep -qa "$CASE_ID" "$f" 2>/dev/null && sudo rm -f "$f"
done

echo "[cleanup] giving back the containerd config and the crictl config of the host..."
RESTART=0
if sudo test -f "$LIB_BASE/config.toml.orig"; then sudo cp -p "$LIB_BASE/config.toml.orig" "$CONFIG"; RESTART=1
elif sudo test -f "$LIB_BASE/config.toml.absent"; then sudo rm -f "$CONFIG"; sudo rmdir /etc/containerd 2>/dev/null; RESTART=1; fi
if sudo test -f "$LIB_BASE/crictl.yaml.orig"; then sudo cp -p "$LIB_BASE/crictl.yaml.orig" "$CRICTL_CONF"
elif sudo test -f "$LIB_BASE/crictl.yaml.absent"; then sudo rm -f "$CRICTL_CONF"; fi
if [ "$RESTART" = 1 ]; then
    restart_containerd 2>/dev/null
    sleep 1
fi

echo "[cleanup] removing the work dir and the case's own records..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE"

echo "[cleanup] done. Environment reset to clean state."
