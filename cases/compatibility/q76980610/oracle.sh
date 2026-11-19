#!/bin/bash
set -e

CASE_ID="bench76980610"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
NR="$WORK_DIR/bin/node-run"

st() { sudo python3 -c 'import json,sys; d=json.load(open(sys.argv[1] + "/state.json")); print(eval(sys.argv[2]))' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }
CTR="$(st "d['ctr']")"
ctr() { timeout -k 3 30 "$NR" "$CTR" --address /run/containerd/containerd.sock "$@" 2>/dev/null; }

st "d['pid']" >/dev/null || fail "setup's record is missing"
PID=$(st "d['pid']"); NODENS=$(st "d['node_ns']")
echo "[oracle] the node's containerd and the engine proxy are the recorded processes (not stopped, not restarted, not replaced, not reconfigured); the test, its jars, the image tar and the wrappers are unchanged..."
sudo test -d "/proc/$PID" || fail "the node's containerd (pid $PID) is gone: it was stopped or restarted"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded containerd any more"
[ "$(sudo readlink "/proc/$PID/ns/mnt")" = "$NODENS" ] || fail "the node's mount namespace changed"
[ "$("$NR" sha256sum /etc/containerd/config.toml | awk '{print $1}')" = "$(st "d['containerd_conf_sha']")" ] || fail "the node's containerd config changed"
[ "$("$NR" sha256sum /etc/docker/daemon.json | awk '{print $1}')" = "$(st "d['daemon_json_sha']")" ] || fail "the node's daemon.json changed"
PPID_=$(st "d['proxy_pid']")
sudo test -d "/proc/$PPID_" || fail "the node's engine proxy (pid $PPID_) is gone: it was stopped or replaced"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PPID_/stat")" = "$(st "d['proxy_start']")" ] || fail "pid $PPID_ is not the recorded engine proxy any more"
[ "$(sudo readlink "/proc/$PPID_/ns/mnt")" = "$NODENS" ] || fail "the engine proxy left the node"
python3 - "$(sudo cat "$STATE_DIR/state.json")" <<'PYEOF' || fail "a jar, the test classes, the image tar or a wrapper changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] in the node: ONE containerd (the node's own, no second one that dockerd started for itself) and a dockerd running on top of it..."
read -r NCTD NDOCKERD < <(sudo python3 - "$NODENS" <<'PYEOF'
import os, sys
ns, c, d = sys.argv[1], 0, 0
for p in os.listdir("/proc"):
    if p.isdigit():
        try:
            if os.readlink("/proc/%s/ns/mnt" % p) != ns:
                continue
            exe = os.path.basename(os.readlink("/proc/%s/exe" % p))
        except OSError:
            continue
        c += exe == "containerd"
        d += exe == "dockerd"
print(c, d)
PYEOF
)
[ "$NCTD" = "1" ] || fail "$NCTD containerd processes run in the node (a dockerd that starts a containerd of its own does not use the node's)"
[ "$NDOCKERD" -ge 1 ] || fail "no dockerd runs in the node: there is no Docker API for Testcontainers"
echo "  -> OK"

echo "[oracle] the job's test, run again: it has to start a container through Testcontainers; meanwhile (the test holds the container) the container has to be in the NODE's containerd with this run's nonce..."
HOLD="$WORK_DIR/hold"; OUT="$WORK_DIR/oracle-test.out"
rm -f "$HOLD" "$OUT"
"$WORK_DIR/bin/run-test" "$HOLD" > "$OUT" 2>&1 &
TP=$!
for _ in $(seq 1 120); do
    grep -q '^STARTED nonce=' "$OUT" 2>/dev/null && break
    kill -0 "$TP" 2>/dev/null || break
    sleep 1
done
grep -q '^STARTED nonce=' "$OUT" || { kill "$TP" 2>/dev/null || true; fail "the test did not start its container: $(grep -v '^\[main\]' "$OUT" | tail -3 | cut -c1-300 | tr '\n' ' ')"; }
NONCE=$(sed -n 's/^STARTED nonce=\([0-9a-f]*\) id=.*/\1/p' "$OUT" | head -1)
CID=$(sed -n 's/^STARTED nonce=[0-9a-f]* id=\([0-9a-f]*\).*/\1/p' "$OUT" | head -1)
FOUND=""
for ns in $(ctr namespaces ls -q); do
    if ctr -n "$ns" containers ls -q | grep -qxF "$CID"; then
        ctr -n "$ns" containers info "$CID" | grep -qF "NONCE=$NONCE" || { touch "$HOLD"; wait "$TP" 2>/dev/null || true; fail "the container $CID of the node's containerd does not carry this run's nonce"; }
        ctr -n "$ns" tasks ls | awk -v id="$CID" '$1 == id {print $3}' | grep -qx RUNNING || { touch "$HOLD"; wait "$TP" 2>/dev/null || true; fail "the container $CID has no running task in the node's containerd"; }
        FOUND="$ns"
    fi
done
[ -n "$FOUND" ] || { touch "$HOLD"; wait "$TP" 2>/dev/null || true; fail "the container $CID that the test started is not in any namespace of the node's containerd (another engine made it)"; }
TPID=$(ctr -n "$FOUND" tasks ls | awk -v id="$CID" '$1 == id {print $2}')
sudo cat "/proc/$TPID/environ" 2>/dev/null | tr '\0' '\n' | grep -qxF "NONCE=$NONCE" || { touch "$HOLD"; wait "$TP" 2>/dev/null || true; fail "the process of the container (pid $TPID) does not have the nonce in its environment"; }
echo "  -> OK (container ${CID:0:12} in namespace '$FOUND' of the node's containerd, task pid $TPID, nonce in its environment)"
touch "$HOLD"
wait "$TP" && RC=0 || RC=$?
[ "$RC" = "0" ] || fail "the Spring Boot test failed after starting the container (exit status $RC): $(grep -v '^\[main\]' "$OUT" | tail -3 | cut -c1-300 | tr '\n' ' ')"
grep -qx "LOG bench76980610-ready nonce=$NONCE" "$OUT" || fail "the test did not report the nonce in the log of its container"
grep -q "^SPRING ctx=" "$OUT" || fail "the Spring application context of the test did not come up"
grep -qE "\[ +1 tests successful" "$OUT" && grep -qE "\[ +0 tests failed" "$OUT" || fail "the JUnit summary does not say '1 tests successful, 0 tests failed'"

echo "[oracle] and the test's own cleanup: its container is gone from the node's containerd..."
for ns in $(ctr namespaces ls -q); do
    ! ctr -n "$ns" containers ls -q | grep -qxF "$CID" || fail "the container of the test is still in the node's containerd (namespace $ns)"
done
echo "  -> OK"
echo "[oracle] all checks passed."
