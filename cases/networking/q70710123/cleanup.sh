#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench70710123"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
PORT=7070
IMAGE_REF="docker.io/library/$CASE_ID:latest"

# Containers made from this case's image, or carrying this case's name (a
# nerdctl container keeps its name in a label, its containerd id is a hash).
# Prints "<namespace> <id>" per container.
list_case_containers() {
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for c in $(sudo ctr -n "$ns" containers ls -q 2>/dev/null); do
            sudo ctr -n "$ns" containers info "$c" 2>/dev/null | python3 -c '
import json, sys
ref, cid = sys.argv[1], sys.argv[2]
try:
    info = json.load(sys.stdin)
except Exception:
    sys.exit(1)
name = (info.get("Labels") or {}).get("nerdctl/name", "")
if info.get("Image") == ref or cid.find(sys.argv[3]) >= 0 or name.find(sys.argv[3]) >= 0:
    sys.exit(0)
sys.exit(1)' "$IMAGE_REF" "$c" "$CASE_ID" && echo "$ns $c"
        done
    done
}

# network namespaces of the case's running containers (one inode string per line): whatever a
# solution started inside one of them (a fake server, ...) is stopped below, after the container
# is gone, even when its command line does not name this case
CASE_NETNS=""
if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    CASE_NETNS=$(list_case_containers | while read -r ns c; do
        pid=$(sudo ctr -n "$ns" tasks ls 2>/dev/null | awk -v n="$c" '$1==n && $3=="RUNNING" {print $2}')
        [ -n "$pid" ] && sudo readlink "/proc/$pid/ns/net"
    done)
fi

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    echo "[cleanup] removing the containers of this case (made from its image, or named after it)"
    echo "[cleanup] and its image from every containerd namespace. Nothing else is touched..."
    list_case_containers | while read -r ns c; do
        # nerdctl first, so that it also tears down the container's CNI network; then plain ctr
        # for whatever is left (or was never nerdctl's)
        if command -v nerdctl >/dev/null 2>&1; then
            timeout -k 5 30 sudo nerdctl -n "$ns" rm -f "$c" >/dev/null 2>&1 </dev/null || true
        fi
        timeout -k 5 20 sudo ctr -n "$ns" tasks kill -s SIGKILL "$c" >/dev/null 2>&1 || true
        timeout -k 5 20 sudo ctr -n "$ns" tasks delete --force "$c" >/dev/null 2>&1 || true
        timeout -k 5 20 sudo ctr -n "$ns" containers delete "$c" >/dev/null 2>&1 || true
    done
    for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
        for ref in $(sudo ctr -n "$ns" images ls -q 2>/dev/null | grep -F "$CASE_ID"); do
            timeout -k 5 60 sudo ctr -n "$ns" images rm --sync "$ref" >/dev/null 2>&1 || true
        done
    done
fi

# `ctr run --cni` never tells CNI to release the address it asked for, and depending on the
# containerd version the reservation (a file named after the IP in /var/lib/cni/networks/<net>/,
# holding the container id, e.g. "default-bench70710123") stays behind after the container is
# gone; a later container with the same name then fails with "duplicate allocation". A solution
# that used ctr instead of nerdctl can leave one. Only files that name this case's container id
# are removed.
echo "[cleanup] releasing CNI address reservations and cached results kept for this case's container id..."
sudo python3 - "$CASE_ID" <<'PYEOF'
import glob, os, sys

case_id = sys.argv[1]
for path in glob.glob("/var/lib/cni/networks/*/*"):
    base = os.path.basename(path)
    if base == "lock" or base.startswith("last_reserved_ip"):
        continue
    try:
        owner = open(path).read().split("\n")[0].strip()      # "<container id>\r\n<ifname>"
    except OSError:
        continue
    if case_id in owner:
        os.remove(path)
        print(f"  released {path} ({owner})")
for path in glob.glob("/var/lib/cni/results/*"):
    if case_id in os.path.basename(path):
        os.remove(path)
        print(f"  removed cached CNI result {path}")
PYEOF

# What a run of this case can have left running: the host's test service, and whatever a
# solution started in the background (a fake server in the container's network namespace is not
# visible as a listener on the host, so processes are found by their command line, which names
# this case, or by living in the network namespace of one of this case's containers). Done only when a run of this case left its state directory behind, i.e. only for
# things this case's own run can have started.
if [ -d "$STATE_DIR" ]; then
    echo "[cleanup] stopping the host's test service and background processes of this case..."
    sudo python3 - "$PORT" "$CASE_ID" "$CASE_NETNS" <<'PYEOF'
import os, signal, sys

port, case_id = sys.argv[1], sys.argv[2]
case_netns = set(sys.argv[3].split())
host_netns = os.readlink("/proc/self/ns/net")
case_netns.discard(host_netns)       # a --network host container shares the host's: not ours to clear

# never kill this script's own process chain (sudo, bash, whoever called it)
skip = {os.getpid()}
pid = os.getppid()
while pid > 1:
    skip.add(pid)
    try:
        pid = int(open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[1])
    except (OSError, ValueError, IndexError):
        break


def kill(pid, why, sig=signal.SIGKILL):
    try:
        os.kill(pid, sig)
        print(f"  killed pid {pid} ({why})")
    except OSError:
        pass


# A `sudo` that wraps a background command of a solution is stopped with SIGTERM, after the
# command itself: sudo then restores the user's terminal settings, which a SIGKILL would leave
# in raw mode (no echo, staircase output) for the shell that ran the benchmark.
sudo_wrappers = []


# 1. processes that listen on the port in the host's network namespace
inodes = set()
for path in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        lines = open(path).read().splitlines()[1:]
    except OSError:
        continue
    for line in lines:
        f = line.split()
        # f[1] local address:port (hex), f[3] state (0A = LISTEN), f[9] socket inode
        if len(f) > 9 and f[3] == "0A" and int(f[1].rsplit(":", 1)[1], 16) == int(port):
            inodes.add(f[9])

SHELLS = ("bash", "sh", "dash", "zsh", "fish", "tmux", "ssh", "sshd", "screen")
for p in filter(str.isdigit, os.listdir("/proc")):
    pid = int(p)
    if pid in skip:
        continue
    try:
        comm = open(f"/proc/{p}/comm").read().strip()
        if comm.startswith(("containerd", "dockerd")):
            continue
        # 2. processes whose command line names this case (the host service, a solution's helper)
        cmdline = open(f"/proc/{p}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
        in_case_netns = bool(case_netns) and os.readlink(f"/proc/{p}/ns/net") in case_netns
        if (case_id in cmdline or in_case_netns) and not comm.startswith(SHELLS):
            if comm == "sudo":
                sudo_wrappers.append((pid, cmdline.strip()[:80]))
            else:
                kill(pid, f"{comm}: {cmdline.strip()[:80]}")
            continue
        if inodes:
            for fd in os.listdir(f"/proc/{p}/fd"):
                target = os.readlink(f"/proc/{p}/fd/{fd}")
                if target.startswith("socket:[") and target[8:-1] in inodes:
                    kill(pid, f"{comm}, it listens on port {port}")
                    break
    except OSError:
        continue

for pid, why in sudo_wrappers:
    kill(pid, f"sudo: {why}", signal.SIGTERM)
PYEOF
fi

# a solution may have edited the host's /etc/hosts; it is put back to what it was at setup
if [ -f "$STATE_DIR/etc_hosts.orig" ] && ! cmp -s "$STATE_DIR/etc_hosts.orig" /etc/hosts; then
    echo "[cleanup] putting /etc/hosts back to its content from setup..."
    sudo cp "$STATE_DIR/etc_hosts.orig" /etc/hosts
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
