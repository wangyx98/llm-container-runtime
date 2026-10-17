#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, nothing running), and every command here may fail without aborting the cleanup.

CASE_ID="bench70704948"
ETC="/etc/$CASE_ID"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"

# The whole lab (containerd, its shims, BuildKit, the build and run containers, the name servers, the download site) lives in ONE network namespace and ONE mount namespace, held by the
# process of $RUN_BASE/anchor.pid. Killing every process of that network namespace removes the bridges, the addresses and the mounts of the lab with it: nothing of it touches the host's
# network, iptables or mount table. The pid is trusted only while its start time is the recorded one (a pid can be reused).
if [ -s "$RUN_BASE/anchor.id" ]; then
    read -r A START < "$RUN_BASE/anchor.id"
    if [ -n "$A" ] && [ "$(sudo awk '{print $22}' "/proc/$A/stat" 2>/dev/null)" = "$START" ]; then
        echo "[cleanup] stopping the lab's VM and everything in it..."
        NS=$(sudo readlink "/proc/$A/ns/net")
        if [ -n "$NS" ] && [ "$NS" != "$(readlink /proc/$$/ns/net)" ]; then
            for _ in 1 2 3 4; do
                for p in /proc/[0-9]*; do
                    pid=${p#/proc/}
                    [ "$pid" = "$$" ] && continue
                    [ "$(sudo readlink "$p/ns/net" 2>/dev/null)" = "$NS" ] && sudo kill -KILL "$pid" 2>/dev/null
                done
                sleep 0.5
            done
        fi
    fi
fi
# a client of the VM (nerdctl, buildctl, buildkitctl) of this case that was left running
for comm in nerdctl buildctl; do
    for pid in $(pgrep -x "$comm" 2>/dev/null); do
        sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$CASE_ID" && sudo kill -KILL "$pid" 2>/dev/null
    done
done
sleep 0.3

# the cgroups of the containers (containerd's namespace $CASE_ID, BuildKit's $CASE_ID-bk): empty directories now, they stay after their processes
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -depth -type d \( -name "$CASE_ID" -o -name "$CASE_ID-bk" -o -path "*/$CASE_ID/*" -o -path "*/$CASE_ID-bk/*" \) -exec rmdir {} \; 2>/dev/null
done

# nothing of the lab may be mounted in the host's mount namespace; if something is (a namespace that outlived the anchor), unmount it, deepest first, before rm -rf walks into it
for base in "$RUN_BASE" "$LIB_BASE" "$WORK_DIR"; do
    for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
        sudo umount -l "$m" 2>/dev/null
    done
done

[ -e "$RUN_BASE/netns_created" ] && sudo rmdir /run/netns 2>/dev/null     # made by setup.sh (no /run/netns before it)

echo "[cleanup] removing the lab's directories (the downloaded BuildKit and nerdctl stay in /var/cache/$CASE_ID)..."
sudo rm -rf "$RUN_BASE" "$LIB_BASE" "$ETC" "$WORK_DIR"

echo "[cleanup] done. Environment reset to clean state."
