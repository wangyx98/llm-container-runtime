#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned) and every command may fail without aborting the cleanup.

CASE_ID="bench77040211"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
ADDR="10.77.40.11"
ALIAS="lo:b77040"

# Kill the processes called $1 (exact process name) that belong to the case: their command line mentions the case id ('pkill -f' would also kill the shell that runs this script).
kill_ours() {   # $1 = comm, $2 = signal
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$CASE_ID"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

echo "[cleanup] stopping the four nodes, the registry and the containers (the runc state below each node's directory names every container)..."
if [ -x "$LIB/bin/nodectl" ]; then
    sudo timeout 120 "$LIB/bin/nodectl" stop all >/dev/null 2>&1 || true
fi
for root in "$LIB"/node*/run/runc "$LIB"/node*/run/runc/*; do
    [ -d "$root" ] || continue
    for id in $(sudo runc --root "$root" list -q 2>/dev/null); do
        sudo runc --root "$root" kill "$id" KILL >/dev/null 2>&1
        sleep 0.2
        sudo runc --root "$root" delete -f "$id" >/dev/null 2>&1
    done
done
for sig in TERM KILL; do
    kill_ours containerd "$sig"
    kill_ours containerd-shim-runc-v2 "$sig"
    kill_ours registry "$sig"
    kill_ours crictl "$sig"
    kill_ours ctr "$sig"
    kill_ours timeout "$sig"
    sleep 1
done

echo "[cleanup] unmounting what the pods and snapshots left below the nodes' directories (deepest first), removing their cgroup directories..."
for _ in 1 2 3; do
    awk '{print $2}' /proc/mounts | grep -e "$CASE_ID" | sort -r | while read -r m; do sudo umount "$m" >/dev/null 2>&1 || sudo umount -l "$m" >/dev/null 2>&1; done
    awk '{print $2}' /proc/mounts | grep -q -e "$CASE_ID" || break
    sleep 1
done
for _ in 1 2 3; do
    sudo find /sys/fs/cgroup -maxdepth 9 -depth -type d -path "*$CASE_ID*" -exec rmdir {} \; 2>/dev/null
    sudo find /sys/fs/cgroup -maxdepth 9 -type d -path "*$CASE_ID*" 2>/dev/null | grep -q . || break
    sleep 1
done

# a solution may have put the lab CA into the host's certificate store (the rules forbid it): it is taken out again, the store is rebuilt
if [ -f "$LIB/pki/ca.crt" ]; then
    marker=$(sed -n 2p "$LIB/pki/ca.crt")
    if [ -n "$marker" ]; then
        changed=0
        for f in $(sudo grep -rlF -- "$marker" /usr/local/share/ca-certificates /usr/share/ca-certificates /etc/ssl/certs 2>/dev/null | grep -v '^/etc/ssl/certs/ca-certificates.crt$'); do
            sudo find /etc/ssl/certs -maxdepth 1 -type l -lname "$f" -delete 2>/dev/null     # the link update-ca-certificates made (it does not remove it by itself)
            sudo rm -f "$f" && changed=1
        done
        if [ "$changed" = 1 ] || sudo grep -qF -- "$marker" /etc/ssl/certs/ca-certificates.crt 2>/dev/null; then
            echo "[cleanup] the lab CA was in the certificate store of this host: rebuilding the store..."
            sudo update-ca-certificates >/dev/null 2>&1 || true
        fi
    fi
fi

echo "[cleanup] removing the registry address, the nodes' directories and the work dir (the downloaded registry release stays in /var/cache/$CASE_ID)..."
if sudo test -f "$WORK_DIR/.bench/alias.py" && sudo python3 "$WORK_DIR/.bench/alias.py" has "$ALIAS" "$ADDR" 2>/dev/null; then
    sudo python3 "$WORK_DIR/.bench/alias.py" del "$ALIAS" "$ADDR" 2>/dev/null
fi
sudo rm -rf "$LIB" "$RUN" "$WORK_DIR" "$WORK_DIR"-* /tmp/"$CASE_ID"-*

echo "[cleanup] done. Environment reset to clean state."
