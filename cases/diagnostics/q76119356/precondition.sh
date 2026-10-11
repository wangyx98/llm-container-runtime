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

fail() { echo "  -> FAIL: $*"; exit 1; }
st() { sudo cat "$STATE_DIR/$1" 2>/dev/null || true; }
alive_same() {   # $1 = recorded process (file $1.id in the state dir: pid + start time), not a zombie
    local pid start
    read -r pid start < "$STATE_DIR/$1.id"
    ! grep -q '^State:[[:space:]]*[ZX]' "/proc/$pid/status" 2>/dev/null \
        && [ "$(sudo awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$start" ]
}
info() {   # $1 = socket: the daemon's own answer, as the JSON the recorded truth has
    docker -H "unix://$1" info --format '{{.DefaultRuntime}}|{{json .Runtimes}}' | python3 -c '
import json, sys
d, r = sys.stdin.read().strip().split("|", 1)
print(json.dumps({"default_runtime": d, "runtimes": sorted(json.loads(r))}))'
}

echo "[precondition] checking what setup recorded: two Docker endpoints, each a dockerd and a containerd of its own, started by setup..."
for p in a-containerd a-dockerd b-containerd b-dockerd; do
    alive_same "$p" || fail "the $p process is not the one setup started"
done
(cd "$STATE_DIR" && sha256sum lib.sh patch_config.py | awk '{print $1}' | cmp -s - helpers.sha) || fail "a helper changed"
[ "$(pgrep -c -x dockerd || true)" -ge 2 ] || fail "fewer than two dockerd processes"
for s in "$SOCK_A" "$SOCK_B"; do
    [ -S "$s" ] || fail "$s is not a socket"
    [ "$(stat -c %G "$s")" = "$(id -gn)" ] || fail "$s does not belong to the group of the current user (clients would need sudo)"
    docker -H "unix://$s" version >/dev/null 2>&1 || fail "no answer on $s"
done
echo "  -> OK"

echo "[precondition] the two daemons are configured differently, and each reports it: its default runtime and its runtimes..."
A=$(info "$SOCK_A"); B=$(info "$SOCK_B")
[ "$A" = "$(st a.truth)" ] && [ "$B" = "$(st b.truth)" ] || fail "a daemon reports other runtimes than setup recorded"
python3 - "$A" "$B" <<'PYEOF' || fail "the two daemons do not differ as expected"
import json
import sys

a, b = (json.loads(x) for x in sys.argv[1:3])
assert a["default_runtime"] == "bench-a-default", a
assert b["default_runtime"] == "runc", b
assert "bench-a-extra" in a["runtimes"] and "bench-b-extra" not in a["runtimes"], a
assert "bench-b-extra" in b["runtimes"] and "bench-a-default" not in b["runtimes"], b
PYEOF
echo "  -> OK: a: $A"
echo "          b: $B"

echo "[precondition] the program of the question: it builds, and whichever endpoint it is given it prints the same, wrong, answer (the bug)..."
[ -f "$APP_DIR/main.go" ] && [ -f "$APP_DIR/go.mod" ] && [ -x "$APP_DIR/rtinfo" ] || fail "$APP_DIR does not hold main.go, go.mod and the built rtinfo"
cmp -s "$APP_DIR/main.go" "$(dirname "$0")/starter/main.go" || fail "main.go is not the starter"
RA=$(cd "$WORK_DIR" && timeout -k 3 30 "$APP_DIR/rtinfo" --host "unix://$SOCK_A" </dev/null) || fail "the starter does not run"
RB=$(cd "$WORK_DIR" && timeout -k 3 30 "$APP_DIR/rtinfo" --host "unix://$SOCK_B" </dev/null) || fail "the starter does not run"
python3 - "$RA" "$RB" "$A" "$B" <<'PYEOF' || fail "the starter does not show the bug: it reports what the daemons report, or it answers differently per endpoint"
import json
import sys

ra, rb, a, b = (json.loads(x) for x in sys.argv[1:5])
key = lambda r: (r["default_runtime"], r["runtimes"])
assert key(ra) == key(rb), "the answer differs per endpoint"
assert key(ra) != (a["default_runtime"], a["runtimes"]) and key(rb) != (b["default_runtime"], b["runtimes"]), "it is right"
PYEOF
echo "  -> OK: $RA for a, the same for b"

echo "[precondition] ALL CHECKS PASSED: two Docker endpoints with different runtime configurations, and a program that answers the same for both."
