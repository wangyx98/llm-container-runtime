#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already
# cleaned, containerd not running), and every command here may fail without
# aborting the cleanup.

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench71513719"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
PORT=8085
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

if command -v ctr >/dev/null 2>&1 && [ -S "$SOCK" ] && sudo ctr version >/dev/null 2>&1; then
    echo "[cleanup] removing the containers of this case (made from its image, or named after it)"
    echo "[cleanup] and its image from every containerd namespace. Nothing else is touched..."
    list_case_containers | while read -r ns c; do
        # nerdctl first, so that it also tears down the container's CNI network and
        # port mapping; then plain ctr for whatever is left (or was never nerdctl's)
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
# holding the container id "default-bench71513719") stays behind after the container is gone.
# The next `ctr run --cni` for the same container name then fails with "has been allocated to
# default-bench71513719, duplicate allocation is not allowed" and leaves the task CREATED.
# Only files that name this case's container id are removed.
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

# Whatever a solution left on the host to forward the port (a process listening on it, a
# NAT rule for it) is removed too. That is done only when a run of this case left its state
# directory behind, i.e. only for things this case's own run can have started; a service of
# the machine that was already using the port before the first run is never touched.
if [ -d "$STATE_DIR" ]; then
    echo "[cleanup] removing forwarders a solution may have left on host port $PORT..."
    sudo python3 - "$PORT" "$CASE_ID" <<'PYEOF'
import os, shlex, signal, subprocess, sys

port, case_id = sys.argv[1], sys.argv[2]

# 1. processes that listen on the port (a socat, a small proxy, ...)
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
if inodes:
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            comm = open(f"/proc/{pid}/comm").read().strip()
            if comm.startswith("containerd") or comm.startswith("dockerd"):
                continue
            for fd in os.listdir(f"/proc/{pid}/fd"):
                target = os.readlink(f"/proc/{pid}/fd/{fd}")
                if target.startswith("socket:[") and target[8:-1] in inodes:
                    print(f"  killing pid {pid} ({comm}), it listens on port {port}")
                    os.kill(int(pid), signal.SIGKILL)
                    break
        except OSError:
            continue

# 2. NAT / filter rules that mention the port (DNAT, REDIRECT, ACCEPT, ...), and the rules
#    CNI wrote for a container of this case (its comment carries the container id, e.g.
#    `id: "default-bench71513719"`); `ctr run --cni` never tears those down by itself
def mentions_port(args):
    for i, a in enumerate(args):
        nxt = args[i + 1] if i + 1 < len(args) else ""
        if a in ("--dport", "--dports", "--to-ports") and port in nxt.replace(":", ",").split(","):
            return True
        if a == "--to-destination" and nxt.endswith(":" + port):
            return True
    return False

for fam in ("iptables", "ip6tables"):
    for tbl in ("nat", "filter", "mangle"):
        try:
            out = subprocess.run([fam, "-t", tbl, "-S"], capture_output=True, text=True).stdout
        except OSError:
            break
        chains = set()
        for line in out.splitlines():
            if not line.startswith("-A "):
                continue
            args = shlex.split(line)
            if mentions_port(args) or case_id in line:
                if "-j" in args and args[args.index("-j") + 1].startswith("CNI-"):
                    chains.add(args[args.index("-j") + 1])
                args[0] = "-D"
                if subprocess.run([fam, "-t", tbl] + args, capture_output=True).returncode == 0:
                    print(f"  deleted ({fam} -t {tbl}): {line}")
        for chain in sorted(chains):
            subprocess.run([fam, "-t", tbl, "-F", chain], capture_output=True)
            if subprocess.run([fam, "-t", tbl, "-X", chain], capture_output=True).returncode == 0:
                print(f"  removed chain ({fam} -t {tbl}): {chain}")
PYEOF
fi

if [ -f "$STATE_DIR/orig_ip_forward" ] && [ -f "$STATE_DIR/orig_route_localnet" ]; then
    echo "[cleanup] putting net.ipv4.ip_forward and net.ipv4.conf.all.route_localnet back..."
    cat "$STATE_DIR/orig_ip_forward" | sudo tee /proc/sys/net/ipv4/ip_forward >/dev/null 2>&1
    cat "$STATE_DIR/orig_route_localnet" | sudo tee /proc/sys/net/ipv4/conf/all/route_localnet >/dev/null 2>&1
fi

echo "[cleanup] removing the work dir..."
sudo rm -rf "$WORK_DIR"

echo "[cleanup] done."
