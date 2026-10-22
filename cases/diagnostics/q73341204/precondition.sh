#!/bin/bash
set -e

CASE_ID="bench73341204"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
BIN="$LIB/bin"
CSOCK="$RUN/containerd.sock"
SVC_RUNC_ROOT="$RUN/containerd-runc/services.linuxkit"
NS="services.linuxkit"
ADDR="127.73.34.12"
PORT=6379
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }
ctr_() { sudo "$BIN/ctr" "$@" 2>&1 | grep -v 'level=warning msg="DEPRECATION'; }
ticks() { sudo awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
jget() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]][sys.argv[3]])' "$STATE_DIR/lab.json" "$1" "$2"; }

echo "[precondition] the lab is as its record says: files unchanged, containerd up, redis and getty the processes setup started..."
sudo sh -c 'cd / && sha256sum -c --quiet "$1/lab.sha"' _ "$STATE_DIR" >/dev/null 2>&1 || fail "a file of the lab was changed"
sudo "$BIN/ctr" version >/dev/null 2>&1 || fail "the containerd of the lab does not answer"
for who in redis getty; do
    pid=$(jget "$who" pid)
    [ "$(ticks "$pid")" = "$(jget "$who" start)" ] || fail "$who is not the process (pid $pid) setup started"
done
echo "  -> OK"

echo "[precondition] the problem as in the question: redis runs on the host (a process, listening), but the getty's runc lists only the stopped onboot container and the default namespace of ctr is empty..."
RPID=$(jget redis pid)
[ "$(sudo cat "/proc/$RPID/comm")" = redis-server ] || fail "pid $RPID is not a redis-server"
OUT=$(sudo "$BIN/runc" list 2>&1)
echo "$OUT" | grep -q "^000-dhcpcd .* stopped " || fail "runc list does not show the stopped 000-dhcpcd: $OUT"
[ "$(echo "$OUT" | tail -n +2 | wc -l)" = 1 ] || fail "runc list shows more than the onboot container: $OUT"
! echo "$OUT" | grep -q redis || fail "runc list shows redis"
[ -z "$(ctr_ c ls -q)" ] || fail "the default namespace of ctr has containers"
[ -z "$(ctr_ t ls -q)" ] || fail "the default namespace of ctr has tasks"
python3 - "$ADDR" "$PORT" <<'PYEOF' || fail "redis does not answer PING at $ADDR:$PORT"
import socket, sys
s = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=3)
s.sendall(b"PING\r\n")
sys.exit(0 if s.recv(16).startswith(b"+PONG") else 1)
PYEOF
echo "  -> OK: runc list: $(echo "$OUT" | tail -1 | awk '{print $1, $3}'); redis is pid $RPID"

echo "[precondition] control: the containerd namespace $NS holds redis and getty; exec in redis reads the configuration (its sha256) and PINGs from inside; a runc with the right root lists them too..."
ctr_ namespaces ls -q | grep -qx "$NS" || fail "the namespace $NS is missing"
ctr_ -n "$NS" c ls -q | sort | tr '\n' ' ' | grep -qx "getty redis " || fail "the containers of $NS are not getty and redis: $(ctr_ -n $NS c ls -q | tr '\n' ' ')"
H=$(ctr_ -n "$NS" t exec --exec-id pre-sha redis sha256sum /etc/redis.conf | awk '{print $1}')
[ "$H" = "$(sudo cat "$STATE_DIR/config.sha256")" ] || fail "the sha256 read by exec ($H) is not the lab's"
[ "$(ctr_ -n "$NS" t exec --exec-id pre-ping redis redis-cli ping)" = PONG ] || fail "redis-cli ping by exec did not answer PONG"
sudo grep -qF "PING name=$(jget redis mnt) " "$RUN/log/redis.log" || fail "the log of redis has no PING from inside its mount namespace"
sudo runc --root "$SVC_RUNC_ROOT" list 2>/dev/null | grep -q "^redis .* running " || fail "runc with the root of $NS does not list redis"
[ "$(ticks "$RPID")" = "$(jget redis start)" ] || fail "the control changed redis"
echo "  -> OK"

sudo sh -c "wc -l < '$RUN/log/redis.log' > '$STATE_DIR/ping.base'"
echo "[precondition] PASS - redis is invisible to the getty's runc and ctr defaults; in $NS it can be listed, read and PINGed by exec."
