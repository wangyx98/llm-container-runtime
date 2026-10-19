#!/bin/bash
# no 'set -e': none of this is guaranteed to exist (first run, already cleaned), and every command here may fail without aborting the cleanup.
# The CNI plugin archive in /var/cache/bench72120811 is kept on purpose (setup.sh checks it against a pinned sha256); delete that directory by hand to free the space.

CASE_ID="bench72120811"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/containerd.sock"

# the containers first, the way their owner stops them (ctr), then the containerd of the case
if [ -S "$SOCK" ]; then
    for ns in $(sudo timeout -k 3 20 ctr --address "$SOCK" namespaces ls -q 2>/dev/null); do
        for t in $(sudo timeout -k 3 20 ctr --address "$SOCK" -n "$ns" tasks ls -q 2>/dev/null); do
            sudo timeout -k 3 20 ctr --address "$SOCK" -n "$ns" tasks delete --force "$t" >/dev/null 2>&1
        done
        for c in $(sudo timeout -k 3 20 ctr --address "$SOCK" -n "$ns" containers ls -q 2>/dev/null); do
            sudo timeout -k 3 20 ctr --address "$SOCK" -n "$ns" containers delete "$c" >/dev/null 2>&1
        done
    done
fi
if [ -s "$RUN/containerd.pid" ]; then
    pid=$(cat "$RUN/containerd.pid"); sudo kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
fi

# whatever of the case still runs: containerd and its shims, the container's program, a process a solution started. Matched by the executable (a file below the case's
# directories, or a process in a container whose root is below them) or by the case's paths on the command line; this script and its parents are never touched.
# Also the owner of every listening TCP socket on port 8080 of the host (a user-space forwarder or a fake server a solution started)
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
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) == 8080:
                inodes.add(c[9])
    except OSError:
        pass
pids = set()
if inodes:
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
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

# the firewall: what the case's solution added is removed again, nothing else is touched. A rule goes when it mentions port 8080 or an address of the two lab networks;
# a chain or an nft table that was not there at setup goes with the rules that jump to it (the baseline is in the state directory; without it only the rules go)
sudo env STATE_DIR="$STATE_DIR" python3 - <<'PYEOF'
import os
import re
import shlex
import subprocess

STATE = os.environ["STATE_DIR"]
PAT = re.compile(r"(--dport 8080\b|--dports? [^ ]*\b8080\b|10\.172\.1[23]\.|bench72120811)")


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return subprocess.CompletedProcess(cmd, 1, "", "")


def lines(name):
    try:
        return open(os.path.join(STATE, name)).read().split("\n")
    except OSError:
        return None


if run(["nft", "--version"]).returncode == 0:
    out = run(["nft", "-a", "list", "ruleset"]).stdout
    fam = tab = chain = None
    for l in out.splitlines():
        m = re.match(r"table (\S+) (\S+) \{", l)
        if m:
            fam, tab, chain = m.group(1), m.group(2), None
            continue
        m = re.match(r"\s+chain (\S+) \{", l)
        if m:
            chain = m.group(1)
            continue
        m = re.search(r"# handle (\d+)$", l)
        if m and chain and re.match(r"\s{2,}\S", l) and PAT.search(l.replace("dport 8080", "--dport 8080")):
            run(["nft", "delete", "rule", fam, tab, chain, "handle", m.group(1)])

if run(["iptables", "--version"]).returncode == 0:
    base = lines("fw.chains")
    for table in ("nat", "filter", "mangle", "raw"):
        for _ in range(30):
            out = run(["iptables-save", "-t", table]).stdout
            rules = [l for l in out.splitlines() if l.startswith("-A ") and PAT.search(l)]
            if not rules:
                break
            for l in rules:
                t = shlex.split(l)
                run(["iptables", "-t", table, "-D"] + t[1:])
        if base is None:
            continue
        out = run(["iptables-save", "-t", table]).stdout
        now = [l[1:].split()[0] for l in out.splitlines() if l.startswith(":")]
        new = [c for c in now if "%s %s" % (table, c) not in base]
        for c in new:
            for _ in range(30):
                out = run(["iptables-save", "-t", table]).stdout
                jumps = [l for l in out.splitlines() if l.startswith("-A ") and re.search(r"-j %s( |$)" % re.escape(c), l)]
                if not jumps:
                    break
                for l in jumps:
                    run(["iptables", "-t", table, "-D"] + shlex.split(l)[1:])
            run(["iptables", "-t", table, "-F", c])
            run(["iptables", "-t", table, "-X", c])

if run(["nft", "--version"]).returncode == 0:
    base = lines("nft.tables")
    if base is not None:
        for l in run(["nft", "list", "tables"]).stdout.splitlines():
            if l.strip() and l not in base:
                p = l.split()
                run(["nft", "delete", "table", p[1], p[2]])
PYEOF

# the kernel's forwarding switch as it was before setup.sh made the lab networks
if sudo test -s "$STATE_DIR/ip_forward.orig"; then
    sudo sh -c "cat '$STATE_DIR/ip_forward.orig' > /proc/sys/net/ipv4/ip_forward" 2>/dev/null
fi

# unmount whatever is still mounted below the case directories (deepest first) BEFORE deleting anything: the two network namespace files are mounts
for _ in 1 2 3; do
    for base in "$RUN" "$LIB" "$WORK_DIR"; do
        for m in $(sudo findmnt -rn -o TARGET 2>/dev/null | grep -E "^$base(/|$)" | sort -r); do
            sudo umount -l "$m" 2>/dev/null || true
        done
    done
done

# the two bridges of the lab (their ports died with the namespaces); the kernel's own interface, so no 'ip' is needed
sudo python3 - <<'PYEOF'
import fcntl
import socket
import struct

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for n in (b"bnch72a", b"bnch72b"):
    try:
        fl = fcntl.ioctl(s, 0x8913, struct.pack("16sH", n, 0))
        f = struct.unpack("16sH", fl[:18])[1]
        fcntl.ioctl(s, 0x8914, struct.pack("16sH", n, f & ~1))
        fcntl.ioctl(s, 0x89a1, n)
    except OSError:
        pass
PYEOF

# the cgroups ctr made for the two container ids (cgroup v1 and v2; rmdir only, so a non-empty one stays) and the empty parent directory of the namespace default
for h in /sys/fs/cgroup /sys/fs/cgroup/*; do
    [ -d "$h/default" ] || continue
    sudo find "$h/default" -depth -type d \( -name some-rabbit -o -name bench72120811-ctl \) -exec rmdir {} \; 2>/dev/null
    sudo rmdir "$h/default" 2>/dev/null
done

# the runc state of the two container ids the case uses (runc's default root is shared with the host's containerd: only these two ids are removed)
sudo rm -rf /run/containerd/runc/default/some-rabbit /run/containerd/runc/default/bench72120811-ctl

echo "[cleanup] removing the state of the case..."
sudo rm -rf --one-file-system "$LIB" "$RUN"
echo "[cleanup] removing the work dir and the files a solution may have left beside it in /tmp..."
sudo rm -rf "$WORK_DIR" "$WORK_DIR"-*

echo "[cleanup] done. Environment reset to clean state."
