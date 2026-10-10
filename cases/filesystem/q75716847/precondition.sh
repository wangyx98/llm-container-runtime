#!/bin/bash
set -e

CASE_ID="bench75716847"
WORK_DIR="/tmp/$CASE_ID"
BUNDLE="$WORK_DIR/bundle"
ROOTFS="$BUNDLE/rootfs"
STATE_DIR="$WORK_DIR/.bench"
CONTAINER="$CASE_ID"
CACHE_DIRS=(client_temp proxy_temp fastcgi_temp uwsgi_temp scgi_temp)
# the capabilities a container of this case may hold: the three that `runc spec` grants, plus the three the start-up of nginx needs (CHOWN: give
# the cache directories to its user; SETGID and SETUID: drop the workers to that user)
ALLOWED_CAPS="CAP_AUDIT_WRITE CAP_KILL CAP_NET_BIND_SERVICE CAP_CHOWN CAP_SETUID CAP_SETGID"

fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
tree_hash() {   # owner, group, mode and type of every file of the rootfs except the cache, logs, run dir, tmp, nginx's own config and web root and the mount points
    sudo find "$ROOTFS" -xdev \( -path "$ROOTFS/var/cache/nginx" -o -path "$ROOTFS/var/log" -o -path "$ROOTFS/run" -o -path "$ROOTFS/tmp" \
        -o -path "$ROOTFS/etc/nginx" -o -path "$ROOTFS/usr/share/nginx/html" -o -path "$ROOTFS/dev" -o -path "$ROOTFS/proc" -o -path "$ROOTFS/sys" \) -prune \
        -o -printf '%U:%G %m %y %P\n' | LC_ALL=C sort | sha256sum | awk '{print $1}'
}
cap_names() {   # $1 = a hex capability mask (as in /proc/PID/status): the names of the capabilities in it, one per line
    python3 - "$1" <<'PYEOF'
import sys

NAMES = ["CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER", "FSETID", "KILL", "SETGID", "SETUID", "SETPCAP", "LINUX_IMMUTABLE",
         "NET_BIND_SERVICE", "NET_BROADCAST", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "IPC_OWNER", "SYS_MODULE", "SYS_RAWIO", "SYS_CHROOT",
         "SYS_PTRACE", "SYS_PACCT", "SYS_ADMIN", "SYS_BOOT", "SYS_NICE", "SYS_RESOURCE", "SYS_TIME", "SYS_TTY_CONFIG", "MKNOD", "LEASE",
         "AUDIT_WRITE", "AUDIT_CONTROL", "SETFCAP", "MAC_OVERRIDE", "MAC_ADMIN", "SYSLOG", "WAKE_ALARM", "BLOCK_SUSPEND", "AUDIT_READ",
         "PERFMON", "BPF", "CHECKPOINT_RESTORE"]
m = int(sys.argv[1], 16)
for i in range(64):
    if m >> i & 1:
        print("CAP_" + (NAMES[i] if i < len(NAMES) else str(i)))
PYEOF
}
proc_field() {  # $1 = pid, $2 = key (e.g. Uid): the rest of that line of /proc/PID/status
    sudo sed -n "s/^$2:[[:space:]]*//p" "/proc/$1/status" 2>/dev/null | head -1
}

echo "[precondition] checking what setup recorded and that no container of this case exists yet..."
for f in config.sha tree.sha files.count token rootfs.kind; do
    sudo test -s "$STATE_DIR/$f" || fail "setup did not record $f"
done
sudo test -f "$BUNDLE/config.json" && sudo test -d "$ROOTFS" || fail "the bundle is missing"
if sudo runc state "$CONTAINER" >/dev/null 2>&1; then fail "a runc container $CONTAINER exists already"; fi
echo "  -> OK ($(st rootfs.kind) rootfs, $(st files.count) files)"

echo "[precondition] checking the bundle's config.json: the runc spec default capabilities (and no CAP_CHOWN, CAP_SETUID or CAP_SETGID), rootfs writable, no terminal,"
echo "[precondition] the command nginx -g 'daemon off;', not privileged..."
[ "$(sudo sha256sum "$BUNDLE/config.json" | awk '{print $1}')" = "$(st config.sha)" ] || fail "config.json is not the one setup wrote"
sudo python3 - "$BUNDLE/config.json" <<'PYEOF' || fail "config.json is not in the expected initial state"
import json
import sys

d = json.load(open(sys.argv[1]))
p, c = d["process"], d["process"]["capabilities"]
want = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"]
assert p["args"] == ["nginx", "-g", "daemon off;"], p["args"]
assert p["terminal"] is False and p["user"]["uid"] == 0 and p["user"]["gid"] == 0
assert d["root"]["readonly"] is False
assert p["noNewPrivileges"] is True
# the sets `runc spec` writes differ between runc versions (older ones have no "ambient"): every set that is there is the three defaults
assert {"bounding", "effective", "permitted"} <= set(c), sorted(c)
for k, caps in c.items():
    assert sorted(caps) == want, (k, caps)
assert {"pid", "network", "ipc", "uts", "mount"} <= {n["type"] for n in d["linux"]["namespaces"]}
PYEOF
echo "  -> OK"

echo "[precondition] checking the rootfs: numeric owners kept (root owns what the image has root own), the five cache directories there and owned by root,"
echo "[precondition] the user nginx is uid/gid 101, the web root holds the random file..."
[ "$(tree_hash)" = "$(st tree.sha)" ] || fail "the rootfs is not as setup left it"
sudo grep -q '^nginx:x:101:101:' "$ROOTFS/etc/passwd" || fail "the user nginx (101:101) is not in the rootfs's /etc/passwd"
for f in usr/sbin/nginx etc/passwd etc/nginx/nginx.conf; do
    [ "$(sudo stat -c %u:%g "$ROOTFS/$f")" = "0:0" ] || fail "$f is not owned by root"
done
for d in "${CACHE_DIRS[@]}"; do
    [ "$(sudo stat -c %u:%g "$ROOTFS/var/cache/nginx/$d")" = "0:0" ] || fail "the cache directory $d is not owned by root"
done
[ "$(sudo cat "$ROOTFS/usr/share/nginx/html/bench.txt")" = "$(st token)" ] || fail "the web root's random file changed"
echo "  -> OK"

# the controls: runc runs with the bundle's own config (copied, under another id, the root path absolute), in the foreground
ctl() {   # $1 = the process args as a JSON list, $2 = output file ; the exit code of runc run is printed
    sudo rm -rf "$WORK_DIR/control"; sudo mkdir -p "$WORK_DIR/control"
    sudo python3 - "$BUNDLE/config.json" "$WORK_DIR/control/config.json" "$ROOTFS" "$1" <<'PYEOF'
import json
import sys

src, dst, rootfs, args = sys.argv[1:5]
d = json.load(open(src))
d["root"]["path"] = rootfs
d["process"]["args"] = json.loads(args)
json.dump(d, open(dst, "w"))
PYEOF
    local rc=0
    sudo timeout -k 3 40 runc run --bundle "$WORK_DIR/control" "$CONTAINER-control" </dev/null >"$2" 2>&1 || rc=$?
    sudo runc delete -f "$CONTAINER-control" >/dev/null 2>&1 || true
    sudo rm -rf "$WORK_DIR/control"
    echo "$rc"
}

echo "[precondition] the bad state, run as the thread runs it: a shell-like diagnostic as uid 0 in the container with the default capabilities..."
RC=$(ctl '["bench-probe"]' "$STATE_DIR/control-probe.txt")
LINE=$(grep -m1 "bench75716847 probe" "$STATE_DIR/control-probe.txt" || true)
echo "     $LINE"
[ "$RC" = 0 ] && [ -n "$LINE" ] || fail "the diagnostic did not run in the container (exit $RC): $(head -c 300 "$STATE_DIR/control-probe.txt")"
grep -q 'uid=0 gid=0 ' <<<"$LINE" || fail "the diagnostic does not run as uid 0"
grep -q 'CapEff=0000000020000420 CapBnd=0000000020000420 ' <<<"$LINE" || fail "the capabilities of the container are not the three defaults (AUDIT_WRITE, KILL, NET_BIND_SERVICE)"
grep -q 'rootfs_write=ok ' <<<"$LINE" || fail "the rootfs is not writable for root in the container"
grep -q 'chown_101=Operation not permitted(1)' <<<"$LINE" || fail "chown to uid 101 does not fail with EPERM in the container: $LINE"
echo "  -> OK (root, but without CAP_CHOWN; the rootfs is writable: it is not the file system)"

echo "[precondition] ... and nginx itself, with the bundle's config as it is: it must die on the chown of the cache directory (the thread's error)..."
RC=$(ctl '["nginx","-g","daemon off;"]' "$STATE_DIR/control-nginx.txt")
echo "     exit $RC: $(grep -m1 'nginx: \[emerg\]' "$STATE_DIR/control-nginx.txt" | cut -c1-150)"
[ "$RC" != 0 ] || fail "nginx ran with the default capabilities: it was expected to fail"
grep -q 'chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)' "$STATE_DIR/control-nginx.txt" \
    || fail "nginx did not fail with the chown error: $(head -c 300 "$STATE_DIR/control-nginx.txt")"
if sudo runc state "$CONTAINER-control" >/dev/null 2>&1; then fail "the control container was not removed"; fi
for d in "${CACHE_DIRS[@]}"; do
    [ "$(sudo stat -c %u:%g "$ROOTFS/var/cache/nginx/$d")" = "0:0" ] || fail "the control changed the owner of the cache directory $d"
done
[ "$(tree_hash)" = "$(st tree.sha)" ] || fail "the control changed the rootfs"
[ "$(sudo sha256sum "$BUNDLE/config.json" | awk '{print $1}')" = "$(st config.sha)" ] || fail "the control changed config.json"
echo "  -> OK"

echo "[precondition] PASS - a bundle whose container runs as root with only the three default capabilities: nginx dies on chown(\"/var/cache/nginx/client_temp\", 101),"
echo "[precondition]        the rootfs is writable and root-owned, and nothing is running."
