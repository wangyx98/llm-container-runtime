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

echo "[oracle] check 0: runc must have a RUNNING container $CONTAINER, made from this bundle (runc's default root: 'runc state')..."
STATE_JSON=$(sudo runc state "$CONTAINER" 2>/dev/null) || fail "runc has no container $CONTAINER: nothing was started (or it was started under another id or another runc root)"
STATUS=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$STATE_JSON")
[ "$STATUS" = running ] || fail "the container $CONTAINER is '$STATUS', not running: nginx died at start-up (run it in the foreground to see why)"
[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["bundle"])' <<<"$STATE_JSON")" = "$BUNDLE" ] || fail "the container $CONTAINER was not made from the bundle $BUNDLE"
INIT=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["pid"])' <<<"$STATE_JSON")
[ "$(sudo stat -Lc %d:%i "/proc/$INIT/root")" = "$(sudo stat -c %d:%i "$ROOTFS")" ] || fail "the root of the container's init process is not the bundle's rootfs"
echo "  -> OK (init pid $INIT)"

echo "[oracle] check 1: the container's processes: the master nginx as root (uid 0) and its workers as uid/gid 101, the user of the image, and no other process..."
PIDS=$(sudo runc ps --format json "$CONTAINER" 2>/dev/null | python3 -c 'import json,sys; print(*(json.load(sys.stdin) or []))')
[ -n "$PIDS" ] || fail "runc lists no process in the container"
WORKERS=""
for p in $PIDS; do
    C=$(sudo cat "/proc/$p/comm" 2>/dev/null || true)
    [ "$C" = nginx ] || fail "process $p of the container is '$C', not nginx"
    if [ "$p" = "$INIT" ]; then
        [ "$(proc_field "$p" Uid)" = "$(printf '0\t0\t0\t0')" ] || fail "the master nginx (pid $p) does not run as root: Uid $(proc_field "$p" Uid)"
    else
        WORKERS="$WORKERS $p"
    fi
done
[ -n "$WORKERS" ] || fail "the master nginx runs alone: it has no worker process (its workers died at start-up: they could not drop to the user nginx)"
for p in $WORKERS; do
    U=$(proc_field "$p" Uid | tr -s '[:space:]' ' '); G=$(proc_field "$p" Gid | tr -s '[:space:]' ' ')
    [ "$U" = "101 101 101 101 " ] || fail "worker $p does not run as uid 101 (Uid: $U): the workers must run as the user nginx, not as root"
    [ "$G" = "101 101 101 101 " ] || fail "worker $p does not run as gid 101 (Gid: $G)"
done
echo "  -> OK (master $INIT as root; workers:$WORKERS as 101)"

echo "[oracle] check 2: not privileged and not more than agreed: every capability set of every process within the three defaults and CAP_CHOWN, CAP_SETUID,"
echo "[oracle]          CAP_SETGID; no_new_privs on; own pid, mount, ipc and uts namespaces..."
for p in $PIDS; do
    for k in CapInh CapPrm CapEff CapBnd CapAmb; do
        EXTRA=$(cap_names "$(proc_field "$p" $k)" | grep -vxF -f <(tr ' ' '\n' <<<"$ALLOWED_CAPS") | tr '\n' ' ' || true)
        [ -z "$EXTRA" ] || fail "process $p has capabilities beyond the agreed set in $k: $EXTRA(allowed: $ALLOWED_CAPS)"
    done
    [ "$(proc_field "$p" NoNewPrivs)" = 1 ] || fail "process $p does not have no_new_privs set"
done
for ns in pid mnt ipc uts; do
    [ "$(sudo readlink "/proc/$INIT/ns/$ns")" != "$(sudo readlink /proc/1/ns/$ns)" ] || fail "the container shares the host's $ns namespace"
done
echo "  -> OK (the master holds: $(cap_names "$(proc_field "$INIT" CapEff)" | tr '\n' ' '))"

echo "[oracle] check 3: the cache directories must be owned by the user nginx (101:101) now..."
for d in "${CACHE_DIRS[@]}"; do
    [ "$(sudo stat -c %u:%g "$ROOTFS/var/cache/nginx/$d" 2>/dev/null)" = "101:101" ] || fail "the cache directory $d is owned by $(sudo stat -c %u:%g "$ROOTFS/var/cache/nginx/$d" 2>/dev/null), not 101:101"
done
echo "  -> OK"

echo "[oracle] check 4: the rootfs outside the places nginx writes is as it was: the owners and modes (numeric) of its files were not rewritten..."
[ "$(tree_hash)" = "$(st tree.sha)" ] || fail "the owners or modes of files of the rootfs were changed (only the cache directories may change owner)"
echo "  -> OK"

echo "[oracle] check 5: nginx really serves: the oracle puts a NEW file with random content into the web root and asks the running container for it over HTTP"
echo "[oracle]          (from inside the container's network namespace, port 80)..."
H=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
BODY=$(python3 -c 'import secrets; print(secrets.token_hex(24))')
echo "$BODY" | sudo tee "$ROOTFS/usr/share/nginx/html/oracle-$H.txt" >/dev/null
sudo chmod 0644 "$ROOTFS/usr/share/nginx/html/oracle-$H.txt"
GOT=$(sudo nsenter -t "$INIT" -n python3 - "/oracle-$H.txt" <<'PYEOF' 2>&1 || true
import fcntl
import socket
import struct
import sys
import time

# the container's loopback interface is down in a fresh network namespace: bring it up (no CNI here)
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    flags = struct.unpack("16sh", fcntl.ioctl(s, 0x8913, struct.pack("16sh", b"lo", 0)))[1]
    fcntl.ioctl(s, 0x8914, struct.pack("16sh", b"lo", flags | 1))
except OSError:
    pass
last = "no answer"
for _ in range(20):
    try:
        c = socket.create_connection(("127.0.0.1", 80), timeout=3)
        c.sendall(("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" % sys.argv[1]).encode())
        data = b""
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
        c.close()
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.decode("latin1").split("\r\n")
        server = [l for l in lines if l.lower().startswith("server:")]
        print("%s|%s|%s" % (lines[0], server[0].split(":", 1)[1].strip() if server else "", body.decode("latin1").strip()))
        sys.exit(0)
    except OSError as e:
        last = "connection failed: %s" % e
        time.sleep(0.5)
print(last)
PYEOF
)
sudo rm -f "$ROOTFS/usr/share/nginx/html/oracle-$H.txt"
case "$GOT" in
    HTTP/1.1\ 200\ OK\|nginx*\|"$BODY") ;;
    *) fail "nginx does not serve the oracle's file: got '$GOT', expected the 200 answer of an nginx server with '$BODY'" ;;
esac
SRV=${GOT#*|}; echo "  -> OK (${GOT%%|*}, Server: ${SRV%%|*})"

echo "[oracle] ALL CHECKS PASSED"
