#!/bin/bash
# Idempotent; no 'set -e'. Removes the node of the case (its containers, networks, containerd), whatever listens on 80/443 because of a sample, the
# firewall rules and chains the CNI plugins added since setup, the lab's bridges and the directories. The downloads in /var/cache/bench77579349 stay (pinned sha256).
CASE_ID="bench77579349"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/containerd.sock"
NERDCTL="$WORK_DIR/bin/nerdctl"

echo "[cleanup] removing the containers and networks of the node (the way their owner does it)..."
if [ -S "$SOCK" ] && [ -x "$NERDCTL" ]; then
    for c in $(sudo timeout -k 3 30 "$NERDCTL" ps -aq 2>/dev/null); do
        sudo timeout -k 3 30 "$NERDCTL" rm -f "$c" >/dev/null 2>&1
    done
    for n in $(sudo timeout -k 3 30 "$NERDCTL" network ls --format '{{.Name}}' 2>/dev/null | grep -vx -e bridge -e host -e none); do
        sudo timeout -k 3 30 "$NERDCTL" network rm "$n" >/dev/null 2>&1
    done
fi

echo "[cleanup] stopping containerd, its shims and anything a sample left that runs from the node's files or listens on 80/443..."
if [ -s "$RUN/containerd.pid" ]; then
    pid=$(cat "$RUN/containerd.pid"); sudo kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
fi
protect=" $$ "
p=$$
while [ "$p" -gt 1 ] 2>/dev/null; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    protect="$protect$p "
done
listeners=$(sudo python3 - <<'PYEOF'
import os
inodes = set()
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for line in open(f).read().splitlines()[1:]:
            c = line.split()
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) in (80, 443):
                inodes.add(c[9])
    except OSError:
        pass
pids = set()
if inodes:
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                for fd in os.listdir("/proc/%s/fd" % d):
                    try:
                        t = os.readlink("/proc/%s/fd/%s" % (d, fd))
                    except OSError:
                        continue
                    if t.startswith("socket:[") and t[8:-1] in inodes:
                        pids.add(d)
            except OSError:
                pass
print(" ".join(sorted(pids)))
PYEOF
)
for _ in 1 2 3; do
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$protect" in *" $pid "*) continue ;; esac
        exe="$(readlink "$d/exe" 2>/dev/null)"
        cmd="$(sudo tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        root="$(sudo readlink "$d/root" 2>/dev/null)"
        case "$exe" in "$LIB"/*|"$RUN"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        case "$root" in "$LIB"/*|"$RUN"/*) sudo kill -KILL "$pid" 2>/dev/null; continue ;; esac
        case "$cmd" in *"$LIB/"*|*"$RUN/"*|*"$WORK_DIR/"*) sudo kill -KILL "$pid" 2>/dev/null ;; esac
    done
    for pid in $listeners; do
        case "$protect" in *" $pid "*) continue ;; esac
        sudo kill -KILL "$pid" 2>/dev/null
    done
    sleep 0.3
done

echo "[cleanup] the firewall: rules and chains the CNI plugins added since setup go (the baseline is in the state directory; without it nothing is touched)..."
sudo env STATE_DIR="$STATE_DIR" python3 - <<'PYEOF'
import os, re, shlex, subprocess

STATE = os.environ["STATE_DIR"]


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return subprocess.CompletedProcess(cmd, 1, "", "")


def norm(l):
    return l.strip()


for table in ("nat", "filter"):
    try:
        base = set(norm(l) for l in open("%s/fw.%s.base" % (STATE, table)).read().splitlines())
    except OSError:
        continue
    for _ in range(40):
        out = run(["iptables-save", "-t", table]).stdout
        extra = [l for l in out.splitlines() if l.startswith("-A ") and norm(l) not in base]
        if not extra:
            break
        for l in extra:
            run(["iptables", "-t", table, "-D"] + shlex.split(l)[1:])
    base_chains = set(l[1:].split()[0] for l in base if l.startswith(":"))
    out = run(["iptables-save", "-t", table]).stdout
    for c in [l[1:].split()[0] for l in out.splitlines() if l.startswith(":")]:
        if c not in base_chains:
            run(["iptables", "-t", table, "-F", c])
            run(["iptables", "-t", table, "-X", c])
PYEOF

echo "[cleanup] unmounting whatever is mounted below the case directories (deepest first), then removing the lab's bridges..."
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done
sudo python3 - "$STATE_DIR" <<'PYEOF'
import fcntl, os, socket, struct, sys

try:
    base = set(open(sys.argv[1] + "/links.base").read().split())
except OSError:
    sys.exit(0)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for n in os.listdir("/sys/class/net"):
    if n in base or not n.startswith(("br-", "nerdctl")):
        continue
    b = n.encode()
    try:
        fl = fcntl.ioctl(s, 0x8913, struct.pack("16sH", b, 0))
        f = struct.unpack("16sH", fl[:18])[1]
        fcntl.ioctl(s, 0x8914, struct.pack("16sH", b, f & ~1))
        fcntl.ioctl(s, 0x89a1, b)
    except OSError:
        pass
PYEOF

echo "[cleanup] removing the directories..."
sudo rm -rf "$LIB" "$RUN" "$WORK_DIR"
echo "[cleanup] done."
exit 0
