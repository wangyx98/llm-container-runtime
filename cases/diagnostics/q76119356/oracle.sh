#!/bin/bash
set -e

CASE_ID="bench76119356"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
APP_DIR="$WORK_DIR/app"
SOCK_A="$RUN_BASE/a/docker.sock"
SOCK_B="$RUN_BASE/b/docker.sock"
SOCK_C="$RUN_BASE/c/docker.sock"
BIN="$WORK_DIR/rtinfo.oracle"

fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
info() {
    docker -H "unix://$1" info --format '{{.DefaultRuntime}}|{{json .Runtimes}}' | python3 -c '
import json, sys
d, r = sys.stdin.read().strip().split("|", 1)
print(json.dumps({"default_runtime": d, "runtimes": sorted(json.loads(r))}))'
}
# stop the third endpoint whatever happens
trap 'cd "$WORK_DIR" 2>/dev/null; . "$STATE_DIR/lib.sh" 2>/dev/null && stop_endpoint c >/dev/null 2>&1 || true' EXIT

echo "[oracle] reading the sources the solution left in $APP_DIR..."
[ -f "$APP_DIR/main.go" ] && [ -f "$APP_DIR/go.mod" ] || fail "$APP_DIR does not hold main.go and go.mod"
cmp -s "$APP_DIR/main.go" "$(dirname "$0")/starter/main.go" && fail "main.go is still the starter"
grep -q '"os/exec"' "$APP_DIR"/*.go && fail "the program runs other programs (os/exec): the runtimes have to come from the Docker API"
grep -qE '/proc|cmdline' "$APP_DIR"/*.go && fail "the program looks at the processes of this machine, not at the daemon behind the endpoint"
echo "  -> OK"

echo "[oracle] the two daemons of setup are the same processes, with nothing run on them..."
for p in a-containerd a-dockerd b-containerd b-dockerd; do
    alive_same "$p" || fail "the $p process is not the one setup started (the solution must not restart or change the daemons)"
done
[ "$(info "$SOCK_A")" = "$(st a.truth)" ] && [ "$(info "$SOCK_B")" = "$(st b.truth)" ] || fail "the runtime configuration of a daemon changed"
echo "  -> OK"

echo "[oracle] building the sources (the binary of the solution is not used: a stale one does not count)..."
cd "$APP_DIR"
if ! GOFLAGS=-mod=mod timeout -k 5 500 go build -o "$BIN" . > "$WORK_DIR/build.log" 2>&1; then
    tail -15 "$WORK_DIR/build.log"
    fail "the program does not build"
fi
rm -f "$WORK_DIR/build.log"
cd "$WORK_DIR"
echo "  -> OK"

echo "[oracle] starting a third endpoint, c, with a default runtime and another one whose names are made now (nothing can be written down beforehand)..."
. "$STATE_DIR/lib.sh"
RND=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
start_endpoint c "bench-c-$RND" "extra-$RND"
C=$(info "$SOCK_C")
python3 - "$C" "$RND" <<'PYEOF' || fail "endpoint c does not report what it was started with"
import json
import sys

c = json.loads(sys.argv[1])
assert c["default_runtime"] == "bench-c-" + sys.argv[2] and "extra-" + sys.argv[2] in c["runtimes"], c
PYEOF
echo "  -> OK: c: $C"

# ask $1 (an endpoint, as a --host value) with the DOCKER_HOST variable at $2 (a decoy: another daemon), and DOCKER_CONTEXT as a trap too
ask() {
    DOCKER_HOST="$2" DOCKER_CONTEXT=decoy timeout -k 3 30 "$BIN" --host "$1" </dev/null 2>"$WORK_DIR/ask.err"
}
check() {   # $1 = what was printed, $2 = the host, $3 = the truth (the daemon's own answer)
    python3 - "$1" "$2" "$3" <<'PYEOF'
import json
import sys

out, host, truth = sys.argv[1:4]
lines = [l for l in out.splitlines() if l.strip()]
assert len(lines) == 1, "one JSON object on stdout is expected, got %d lines" % len(lines)
r = json.loads(lines[0])
t = json.loads(truth)
assert set(r) == {"host", "default_runtime", "runtimes"}, "keys: %s" % sorted(r)
assert r["host"] == host, "host is %r, not the endpoint that was given" % r["host"]
assert r["default_runtime"] == t["default_runtime"], "default_runtime %r, the daemon's is %r" % (r["default_runtime"], t["default_runtime"])
assert isinstance(r["runtimes"], list) and sorted(r["runtimes"]) == t["runtimes"], "runtimes %s, the daemon's are %s" % (r["runtimes"], t["runtimes"])
assert r["runtimes"] == sorted(r["runtimes"]), "runtimes are not sorted"
PYEOF
}

echo "[oracle] the program on each endpoint in turn (a, b, c, then a again), with DOCKER_HOST naming another daemon: the answer is the one of the endpoint given..."
TA=$(st a.truth); TB=$(st b.truth)
n=0
for step in "a:$SOCK_A:$SOCK_B:$TA" "b:$SOCK_B:$SOCK_C:$TB" "c:$SOCK_C:$SOCK_A:$C" "a:$SOCK_A:$SOCK_C:$TA"; do
    IFS=: read -r name sock decoy truth <<< "$step"
    n=$((n + 1))
    OUT=$(ask "unix://$sock" "unix://$decoy") || { cat "$WORK_DIR/ask.err"; fail "step $n: the program fails on a working endpoint ($name)"; }
    MSG=$(check "$OUT" "unix://$sock" "$truth" 2>&1) || fail "step $n, endpoint $name: $(echo "$MSG" | tail -1)"
    echo "  -> endpoint $name: $OUT"
done

echo "[oracle] the endpoints that are not a Docker daemon: a clear failure (non-zero exit, a message on stderr, no answer on stdout), never a guess..."
python3 - "$WORK_DIR" <<'PYEOF'
import os
import socket
import sys

# a socket nobody listens on: a file that was a listening socket
p = sys.argv[1] + "/dead.sock"
s = socket.socket(socket.AF_UNIX)
if os.path.exists(p):
    os.unlink(p)
s.bind(p)
s.listen(1)
s.close()
PYEOF
for bad in "unix://$WORK_DIR/nothing-here.sock" "unix://$WORK_DIR/dead.sock" "unix://$RUN_BASE/a/containerd.sock" "tcp://127.0.0.1:1"; do
    set +e
    OUT=$(ask "$bad" "unix://$SOCK_A")
    RC=$?
    set -e
    [ "$RC" -ne 0 ] || fail "$bad is not a Docker daemon and the program succeeds: $OUT"
    [ "$RC" -ne 124 ] && [ "$RC" -ne 137 ] || fail "the program hangs on $bad"
    [ -z "$(echo "$OUT" | tr -d '[:space:]')" ] || fail "the program prints an answer for $bad: $OUT"
    [ -s "$WORK_DIR/ask.err" ] || fail "no message on stderr for $bad"
    echo "  -> $bad: exit $RC, '$(head -c 90 "$WORK_DIR/ask.err" | head -1)'"
done
set +e; OUT=$(timeout -k 3 30 "$BIN" </dev/null 2>/dev/null); RC=$?; set -e
[ "$RC" -ne 0 ] && [ -z "$(echo "$OUT" | tr -d '[:space:]')" ] || fail "without --host the program must fail, it printed: $OUT"
echo "  -> no --host: exit $RC"

echo "[oracle] nothing was run on the daemons: no container and no image on a, b or c, and the first two are the same processes still..."
for p in a-containerd a-dockerd b-containerd b-dockerd; do
    alive_same "$p" || fail "the $p process changed"
done
for s in "$SOCK_A" "$SOCK_B" "$SOCK_C"; do
    [ -z "$(docker -H "unix://$s" ps -aq)" ] || fail "a container exists on $s"
done
[ "$(info "$SOCK_A")" = "$TA" ] && [ "$(info "$SOCK_B")" = "$TB" ] || fail "the runtime configuration of a daemon changed"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED: the program reports the default runtime and the runtimes of the daemon behind the endpoint it is given, for three endpoints, and fails clearly on the others."
