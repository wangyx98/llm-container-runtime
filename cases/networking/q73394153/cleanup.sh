#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned, a daemon not running), and every command here may fail without aborting the cleanup.

CASE_ID="bench73394153"
ETC="/etc/$CASE_ID"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
# k3s keeps files in fixed places outside the case's directories. They are removed only when setup.sh left this marker, i.e. when they are the case's own (setup.sh refuses to start on a host that has them).
OWNED_MARKER="$LIB_BASE/k3s_host_dirs_owned"
HOST_DIRS="/etc/rancher /var/lib/rancher /var/lib/kubelet /run/k3s"

# Kill the processes called $1 (exact process name) whose command line mentions $3. Matching by name first and by command line second is deliberate: 'pkill -f <text>' would also
# kill any shell whose own command line merely contains the text, including the one running this script.
kill_ours() {   # $1 = comm, $2 = signal, $3 = text of the command line
    local pid
    for pid in $(pgrep -x "$1" 2>/dev/null); do
        if sudo tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$3"; then
            sudo kill "-$2" "$pid" 2>/dev/null || true
        fi
    done
}

echo "[cleanup] stopping the registry and the proxy of the lab..."
kill_ours python3 TERM "$WORK_DIR/.bench/"
# a nerdctl, kubectl or k3s client of this case that was left running (or stopped by the terminal: SIGTTIN) keeps its parents alive; SIGKILL works on a stopped process
for comm in nerdctl kubectl; do kill_ours "$comm" KILL "$CASE_ID"; done
kill_ours sudo KILL "$LIB_BASE/"

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] stopping k3s (the one this case started; its own containerd goes with it) and what it left behind..."
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -TERM "$p" 2>/dev/null || true; done
    for _ in $(seq 1 40); do pgrep -x k3s-server >/dev/null 2>&1 || break; sleep 1; done
    for p in $(pgrep -x k3s-server 2>/dev/null); do sudo kill -KILL "$p" 2>/dev/null || true; done
    # the daemon and the shims of k3s' containerd name its socket
    for comm in containerd containerd-shim containerd-shim-runc-v2; do
        kill_ours "$comm" KILL "/run/k3s/"
    done
    # the processes of the containers outlive their shims. A container process has a mount namespace of its own whose mounts are overlays below $LIB_BASE; every process in OUR mount
    # namespace sees those mounts too (the host's), so only the processes of other mount namespaces that mention the case are killed
    mine=$(readlink /proc/$$/ns/mnt)
    for _ in 1 2 3; do
        for m in $(sudo grep -l "$CASE_ID" /proc/[0-9]*/mountinfo 2>/dev/null); do
            p=${m#/proc/}; p=${p%/mountinfo}
            [ "$(sudo readlink "/proc/$p/ns/mnt" 2>/dev/null)" = "$mine" ] && continue
            sudo kill -KILL "$p" 2>/dev/null || true
        done
        sleep 0.3
    done
fi
sleep 0.3

# Unmount whatever is still mounted below the case directories and below the k3s directories (deepest first) BEFORE deleting anything: rm -rf must never walk into a live mount (the
# kubelet's own bind mounts, the overlay mounts of a container, shm).
for _ in 1 2 3; do
    bases="$RUN_BASE $LIB_BASE $WORK_DIR $ETC"
    [ -e "$OWNED_MARKER" ] && bases="$bases /var/lib/kubelet /var/lib/rancher /run/k3s"
    for base in $bases; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

if [ -e "$OWNED_MARKER" ]; then
    echo "[cleanup] removing the cgroups of the containers (empty directories left by killed shims) and the files k3s keeps outside the case's directories..."
    for h in /sys/fs/cgroup /sys/fs/cgroup/*/; do
        for d in "$h"/default "$h"/k8s.io; do
            [ -d "$d" ] && sudo find "$d" -depth -mindepth 1 -type d -exec rmdir {} + 2>/dev/null
            [ -d "$d" ] && sudo rmdir "$d" 2>/dev/null
        done
    done
    for d in $HOST_DIRS; do sudo rm -rf --one-file-system "$d"; done
    # the kubelet's pod logs of this case, and the two directories it creates (and never removes: rmdir removes them only when empty)
    sudo rm -rf /var/log/pods/*_bench73394153-* /var/log/pods/*bench73394153* 2>/dev/null
    sudo find /var/log/containers -maxdepth 1 -name '*bench73394153*' -delete 2>/dev/null
    sudo rmdir /var/log/pods /var/log/containers 2>/dev/null || true
fi

echo "[cleanup] removing the files of the lab and of the solutions (the VM's /etc, the state, the work dir, a name in /etc/hosts)..."
sudo rm -rf --one-file-system "$ETC" "$RUN_BASE" "$LIB_BASE"
grep -q "$CASE_ID" /etc/hosts 2>/dev/null && sudo sed -i "/$CASE_ID/d" /etc/hosts
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*
# /var/cache/$CASE_ID (the downloaded and checked k3s and nerdctl) stays

echo "[cleanup] done. Environment reset to clean state."
