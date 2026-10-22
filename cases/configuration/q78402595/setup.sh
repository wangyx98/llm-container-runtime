#!/bin/bash
set -e

CASE_ID="bench78402595"
RUN_BASE="/run/$CASE_ID"              # containerd's socket, state directory, pid file and log
LIB_BASE="/var/lib/$CASE_ID"          # bin (ctr, containerdctl), libexec (containerd and its shims), etc (configuration), root (containerd's root), the values the lab changed (orig.*)
CTL_DIR="$LIB_BASE/bin"               # control scripts (not in /run: it is mounted noexec on many hosts)
LIBEXEC="$LIB_BASE/libexec"
CACHE="/var/cache/$CASE_ID"           # the downloaded and checked containerd release (kept by cleanup.sh)
SOCK="$RUN_BASE/containerd.sock"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NS="bench78402595"                    # the containerd namespace of the lab
REF="docker.io/library/bench78402595-app:1"
LEAKS=16                              # processes left behind in the container by the "probe runs" of the story

# containerd 1.5.7 has no arm64 release (the first one is 1.6.0): x86_64 gets the version of the question, aarch64 the oldest official arm64 build
case "$(uname -m)" in
    x86_64)        CTD_VERSION="1.5.7"; CTD_ASSET="containerd-1.5.7-linux-amd64.tar.gz"; CTD_SHA256="109fc95b86382065ea668005c376360ddcd8c4ec413e7abe220ae9f461e0e173"; IMG_ARCH="amd64" ;;
    aarch64|arm64) CTD_VERSION="1.6.0"; CTD_ASSET="containerd-1.6.0-linux-arm64.tar.gz"; CTD_SHA256="6eff3e16d44c89e1e8480a9ca078f79bab82af602818455cc162be344f64686a"; IMG_ARCH="arm64" ;;
    *)             CTD_VERSION=""; CTD_ASSET=""; CTD_SHA256=""; IMG_ARCH="" ;;
esac

echo "[setup] checking runc, gcc, curl, tar, python3 and sha256sum of this machine..."
for b in runc gcc curl tar python3 sha256sum; do
    command -v "$b" >/dev/null || { echo "[setup] ERROR: $b not found"; exit 1; }
done
[ -n "$CTD_ASSET" ] || { echo "[setup] ERROR: no containerd is pinned for the architecture $(uname -m) (x86_64 and aarch64 are)"; exit 1; }
[ -w /proc/sys/net/core/bpf_jit_limit ] || sudo test -w /proc/sys/net/core/bpf_jit_limit || { echo "[setup] ERROR: net.core.bpf_jit_limit does not exist (a kernel without BPF JIT)"; exit 1; }
echo "  host: $(runc --version | head -1), kernel $(uname -r) $(uname -m), cgroup $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$(dirname "$0")/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR"
chmod 755 "$WORK_DIR"
chmod 700 "$STATE_DIR"
cd "$WORK_DIR"

# what the lab is going to change on the host, recorded first (cleanup.sh puts it back)
sudo mkdir -p "$LIB_BASE" "$CACHE" "$CTL_DIR" "$LIBEXEC" "$LIB_BASE/etc" "$LIB_BASE/root" "$RUN_BASE/state"
for k in bpf_jit_limit bpf_jit_enable bpf_jit_harden; do
    [ -e "/proc/sys/net/core/$k" ] && sudo sh -c "cat /proc/sys/net/core/$k > \"$LIB_BASE/orig.$k\""
done
sudo cp "$LIB_BASE/orig.bpf_jit_limit" "$LIB_BASE/default_bpf_jit_limit"
sudo chmod 644 "$LIB_BASE/default_bpf_jit_limit"
# the runc state and the shim sockets of containerd live in shared places: record what is there now
sudo sh -c "find /run/containerd/s -maxdepth 1 -mindepth 1 2>/dev/null | sort > \"$LIB_BASE/shims.before\""
[ -e /run/containerd ] || sudo touch "$LIB_BASE/run_containerd_created"
# restore the limit if this script stops early
trap 'sudo sh -c "cat \"$LIB_BASE/orig.bpf_jit_limit\" > /proc/sys/net/core/bpf_jit_limit" 2>/dev/null || true' EXIT

echo "[setup] containerd $CTD_VERSION: from the cache $CACHE, else downloaded; the sha256 is checked either way..."
if ! { sudo test -f "$CACHE/$CTD_ASSET" && echo "$CTD_SHA256  $CACHE/$CTD_ASSET" | sudo sha256sum -c - >/dev/null 2>&1; }; then
    if [ -n "${BENCH78402595_CONTAINERD_TGZ:-}" ]; then cp "$BENCH78402595_CONTAINERD_TGZ" "$STATE_DIR/download"
    else curl -fsSL --retry 3 --max-time 600 -o "$STATE_DIR/download" "https://github.com/containerd/containerd/releases/download/v$CTD_VERSION/$CTD_ASSET" || { echo "[setup] ERROR: could not download containerd $CTD_VERSION"; exit 1; }
    fi
    echo "$CTD_SHA256  $STATE_DIR/download" | sha256sum -c - >/dev/null 2>&1 || { echo "[setup] ERROR: the containerd archive has the wrong sha256"; exit 1; }
    sudo install -m 644 "$STATE_DIR/download" "$CACHE/$CTD_ASSET"
    rm -f "$STATE_DIR/download"
fi
mkdir -p "$STATE_DIR/ctd"
tar -xzf "$CACHE/$CTD_ASSET" -C "$STATE_DIR/ctd"
for b in containerd containerd-shim containerd-shim-runc-v2 ctr; do
    sudo install -m 755 "$STATE_DIR/ctd/bin/$b" "$LIBEXEC/$b"
done

echo "[setup] the program of the container (one static binary: sleep, hold, probe) and its image..."
cat > "$STATE_DIR/app.c" <<'CEOF'
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc > 1 && (!strcmp(argv[1], "sleep") || !strcmp(argv[1], "hold")))
        for (;;) pause();
    /* probe: what the container's seccomp profile says about a syscall it forbids (a new user namespace) */
    int rc = unshare(CLONE_NEWUSER), err = rc ? errno : 0, sc = -1;
    char line[256];
    FILE *f = fopen("/proc/self/status", "r");
    while (f && fgets(line, sizeof line, f))
        if (!strncmp(line, "Seccomp:", 8)) sc = atoi(line + 8);
    printf("probe seccomp=%d userns_rc=%d userns_errno=%d\n", sc, rc, err);
    return 0;
}
CEOF
gcc -static -Os -s -w -o "$STATE_DIR/app" "$STATE_DIR/app.c"
cat > "$STATE_DIR/mkarchive.py" <<'PYEOF'
"""mkarchive.py OUT REF PROGRAM ARCH : a one-layer docker archive (docker save format) with PROGRAM as /app"""
import hashlib
import io
import json
import sys
import tarfile

out, ref, prog, arch = sys.argv[1:5]


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    with open(prog, "rb") as f:
        data = f.read()
    ti = tarfile.TarInfo("app")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Entrypoint": ["/app"], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, payload in (("manifest.json", manifest), (sha(config) + ".json", config), (sha(layer) + "/layer.tar", layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(payload), 1700000000
        t.addfile(ti, io.BytesIO(payload))
PYEOF
python3 "$STATE_DIR/mkarchive.py" "$STATE_DIR/app.tar" "$REF" "$STATE_DIR/app" "$IMG_ARCH"

echo "[setup] the control scripts: containerdctl (start, stop, restart, status) and ctr aimed at this containerd and its namespace..."
sudo tee "$LIB_BASE/etc/config.toml" >/dev/null <<TEOF
version = 2
disabled_plugins = ["io.containerd.grpc.v1.cri"]
TEOF
sudo tee "$CTL_DIR/containerdctl" >/dev/null <<CTLEOF
#!/bin/bash
# containerdctl start|stop|restart|status : the private containerd $CTD_VERSION of this lab (needs root: it runs itself with sudo)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
RUN="$RUN_BASE"; LIB="$LIB_BASE"
PIDFILE="\$RUN/containerd.pid"
running() {
    local p; p=\$(cat "\$PIDFILE" 2>/dev/null) || return 1
    [ -n "\$p" ] && tr '\0' ' ' 2>/dev/null < "/proc/\$p/cmdline" | grep -q -- "--address \$RUN/containerd.sock"
}
case "\$1" in
    start)
        running && { echo "containerd is already running"; exit 0; }
        mkdir -p "\$RUN/state"
        rm -f "\$RUN/containerd.sock" "\$RUN/containerd.sock.ttrpc"
        PATH="\$LIB/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" setsid nohup "\$LIB/libexec/containerd" --config "\$LIB/etc/config.toml" --root "\$LIB/root" --state "\$RUN/state" --address "\$RUN/containerd.sock" --log-level info >"\$RUN/containerd.log" 2>&1 </dev/null &
        echo \$! > "\$PIDFILE"
        for i in \$(seq 1 60); do [ -S "\$RUN/containerd.sock" ] && "\$LIB/libexec/ctr" -a "\$RUN/containerd.sock" version >/dev/null 2>&1 && { echo "containerd started"; exit 0; }; sleep 0.5; done
        echo "containerd did not come up (see \$RUN/containerd.log)"; exit 1 ;;
    stop)
        running || { echo "containerd is not running"; exit 0; }
        p=\$(cat "\$PIDFILE"); kill -TERM "\$p"
        for i in \$(seq 1 40); do kill -0 "\$p" 2>/dev/null || break; sleep 0.5; done
        kill -0 "\$p" 2>/dev/null && kill -KILL "\$p"
        rm -f "\$PIDFILE"; echo "containerd stopped" ;;
    restart) "\$0" stop; "\$0" start ;;
    status) running && echo "containerd is running (pid \$(cat "\$PIDFILE"))" || { echo "containerd is not running"; exit 3; } ;;
    *) echo "usage: containerdctl start|stop|restart|status"; exit 2 ;;
esac
CTLEOF
sudo tee "$CTL_DIR/ctr" >/dev/null <<CTLEOF
#!/bin/bash
# ctr aimed at the private containerd and its namespace $NS (needs root: it runs itself with sudo)
[ "\$(id -u)" = 0 ] || exec sudo "\$0" "\$@"
exec "$LIBEXEC/ctr" --address "$SOCK" --namespace "$NS" "\$@"
CTLEOF
sudo chmod 755 "$CTL_DIR/containerdctl" "$CTL_DIR/ctr"

echo "[setup] starting containerd and the container (the default seccomp profile, no extra capabilities)..."
sudo "$CTL_DIR/containerdctl" start
sudo "$CTL_DIR/ctr" images import "$STATE_DIR/app.tar" >/dev/null
sudo "$CTL_DIR/ctr" run -d --seccomp "$REF" tgt /app sleep
for i in $(seq 1 30); do sudo "$CTL_DIR/ctr" tasks ls 2>/dev/null | awk '$1=="tgt" && $3=="RUNNING"' | grep -q . && break; sleep 0.5; done
sudo "$CTL_DIR/ctr" tasks ls | awk '$1=="tgt" && $3=="RUNNING"' | grep -q . || { echo "[setup] ERROR: the container tgt does not run"; exit 1; }
sudo "$CTL_DIR/ctr" tasks exec --exec-id s0 tgt /app probe | grep -q "seccomp=2 userns_rc=-1 userns_errno=1" || { echo "[setup] ERROR: the probe of the fresh container does not show the profile"; exit 1; }

# the container as it is: the oracle compares it with what is left after the solution
sudo "$CTL_DIR/ctr" containers info tgt | python3 -c '
import json
import sys

d = json.load(sys.stdin)
spec = d["Spec"]
sec = spec.get("linux", {}).get("seccomp") or {}
caps = spec["process"].get("capabilities", {})
print(json.dumps({"image": d["Image"], "seccomp_default": sec.get("defaultAction"), "seccomp_rules": len(sec.get("syscalls", [])),
                  "bounding": sorted(caps.get("bounding", [])), "effective": sorted(caps.get("effective", [])),
                  "no_new_privileges": spec["process"].get("noNewPrivileges", False), "user": spec["process"].get("user")}, sort_keys=True))' > "$STATE_DIR/spec.json"
python3 -c '
import json
import sys
d = json.load(open(sys.argv[1]))
assert d["seccomp_default"] and d["seccomp_rules"] >= 5, d
assert not {"CAP_SYS_ADMIN", "CAP_BPF", "CAP_PERFMON"} & set(d["bounding"]), d' "$STATE_DIR/spec.json" || { echo "[setup] ERROR: the container does not have the profile or has too many capabilities"; exit 1; }

echo "[setup] measuring the JIT memory: the smallest limit under which one more exec of the profile loads (binary search with the real exec)..."
cat > "$STATE_DIR/lmin.sh" <<'LEOF'
#!/bin/bash
# lmin.sh CTR : print the smallest net.core.bpf_jit_limit under which `ctr tasks exec tgt /app probe` works, in steps of 64 bytes; puts the limit back
CTR="$1"; LIM=/proc/sys/net/core/bpf_jit_limit
hi=$(cat $LIM); hi0=$hi; lo=1; n=0
trap 'echo $hi0 > $LIM' EXIT
"$CTR" tasks exec --exec-id "m$$-0" tgt /app probe >/dev/null 2>&1 || { echo "the exec does not work with the limit $hi" >&2; exit 1; }
while [ $((hi - lo)) -gt 64 ]; do
    mid=$(((lo + hi) / 2)); echo $mid > $LIM; n=$((n + 1))
    if "$CTR" tasks exec --exec-id "m$$-$n" tgt /app probe >/dev/null 2>&1; then hi=$mid; else lo=$mid; fi
done
echo $hi
LEOF
L0=$(sudo bash "$STATE_DIR/lmin.sh" "$CTL_DIR/ctr")
echo "  one exec more fits under a limit of $L0 bytes (the container alone)"

echo "[setup] $LEAKS processes of 'probe runs' that were never reaped (each keeps the seccomp filter of its exec loaded)..."
for i in $(seq 1 $LEAKS); do sudo "$CTL_DIR/ctr" tasks exec -d --exec-id "run$i" tgt /app hold; done
NHOLD=0; for p in /proc/[0-9]*; do [ "$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")" = "/app hold " ] && NHOLD=$((NHOLD + 1)); done
[ "$NHOLD" = "$LEAKS" ] || { echo "[setup] ERROR: $NHOLD of $LEAKS leftover processes run"; exit 1; }
LN=$(sudo bash "$STATE_DIR/lmin.sh" "$CTL_DIR/ctr")
C=$(((LN - L0) / LEAKS))
[ "$C" -ge 64 ] || { echo "[setup] ERROR: the JIT memory of an exec is not measurable (L0=$L0, L$LEAKS=$LN)"; exit 1; }
[ "$C" -ge 4096 ] || { echo "[setup] ERROR: one exec costs only $C bytes of JIT memory (L0=$L0, L$LEAKS=$LN): too little to calibrate"; exit 1; }
MARGIN=$((C / 4)); [ "$MARGIN" -ge 8192 ] || MARGIN=8192; [ "$MARGIN" -le $((C / 2)) ] || MARGIN=$((C / 2))     # how far below "one more exec fits" the limit is (kernels that count whole pages need at least a page)
T=$((LN - MARGIN))
echo "  with $LEAKS leftovers one more exec needs $LN bytes: one exec costs about $C bytes; the node's limit is set to $T (default $(cat "$LIB_BASE/orig.bpf_jit_limit"))"
sudo sh -c "echo $T > /proc/sys/net/core/bpf_jit_limit"
printf 'L0=%s\nLN=%s\nC=%s\nT=%s\nLEAKS=%s\n' "$L0" "$LN" "$C" "$T" "$LEAKS" > "$STATE_DIR/calib.env"
if sudo "$CTL_DIR/ctr" tasks exec --exec-id s1 tgt /app probe >/dev/null 2>&1; then
    echo "[setup] ERROR: an exec still works under the limit $T"; exit 1
fi
trap - EXIT

echo "[setup] ready: the container tgt with $LEAKS leftover processes, net.core.bpf_jit_limit = $T"
