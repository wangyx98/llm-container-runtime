#!/bin/bash
set -e

CASE_ID="bench71379578"
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
echo "[oracle] the node's containerd is the recorded process (not stopped, not restarted, not reconfigured); the node's dockerd and the pod are the recorded ones; the test, its jars, the image tar and the wrappers are unchanged..."
sudo test -d "/proc/$PID" || fail "the node's containerd (pid $PID) is gone: it was stopped or restarted"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st "d['start']")" ] || fail "pid $PID is not the recorded containerd any more"
[ "$(sudo readlink "/proc/$PID/ns/mnt")" = "$NODENS" ] || fail "the node's mount namespace changed"
[ "$("$NR" sha256sum /etc/containerd/config.toml | awk '{print $1}')" = "$(st "d['containerd_conf_sha']")" ] || fail "the node's containerd config changed"
[ "$("$NR" sha256sum /etc/docker/daemon.json | awk '{print $1}')" = "$(st "d['daemon_json_sha']")" ] || fail "the node's daemon.json changed"
DPID=$(st "d['dockerd_pid']"); POD=$(st "d['pod_pid']"); NODEIP=$(st "d['node_ip']")
sudo test -d "/proc/$DPID" || fail "the node's dockerd (pid $DPID) is gone: it was stopped or restarted"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$DPID/stat")" = "$(st "d['dockerd_start']")" ] || fail "pid $DPID is not the recorded dockerd any more"
sudo test -d "/proc/$POD" && [ "$(sudo readlink "/proc/$POD/ns/net")" = "$(st "d['pod_ns']")" ] || fail "the pod's network namespace is not the recorded one any more"
python3 - "$(sudo cat "$STATE_DIR/state.json")" <<'PYEOF' || fail "a jar, the test classes, the image tar or a wrapper changed"
import hashlib, json, sys
for f, h in json.loads(sys.argv[1])["files"].items():
    if hashlib.sha256(open(f, "rb").read()).hexdigest() != h:
        sys.exit(1)
PYEOF
echo "  -> OK"

echo "[oracle] in the node: ONE containerd (the node's own, no second one that a dockerd started for itself) and the dockerd of setup on top of it..."
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
[ "$NDOCKERD" = "1" ] || fail "$NDOCKERD dockerd processes run in the node (expected the one of setup)"
echo "  -> OK"

echo "[oracle] the job's test, run again (in the pod): it has to start a container through Testcontainers AND reach its published port; meanwhile (the test holds the container) the container has to be in the NODE's containerd with this run's nonce..."
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
HOSTSEEN=$(sed -n 's/^STARTED nonce=[0-9a-f]* id=[0-9a-f]* host=\([^ ]*\) port=\([0-9]*\).*/\1/p' "$OUT" | head -1)
PORTSEEN=$(sed -n 's/^STARTED nonce=[0-9a-f]* id=[0-9a-f]* host=\([^ ]*\) port=\([0-9]*\).*/\2/p' "$OUT" | head -1)
TPID=$(ctr -n "$FOUND" tasks ls | awk -v id="$CID" '$1 == id {print $2}')
sudo cat "/proc/$TPID/environ" 2>/dev/null | tr '\0' '\n' | grep -qxF "NONCE=$NONCE" || { touch "$HOLD"; wait "$TP" 2>/dev/null || true; fail "the process of the container (pid $TPID) does not have the nonce in its environment"; }
echo "  -> OK (container ${CID:0:12} in namespace '$FOUND' of the node's containerd, task pid $TPID, nonce in its environment)"
echo "[oracle] the address the test used for the published port is an address of the NODE (not localhost of the pod), and the port is held by the node's docker-proxy..."
case "$HOSTSEEN" in 127.*|localhost|""|::1) touch "$HOLD"; wait "$TP" 2>/dev/null || true; fail "the test reached the port at '$HOSTSEEN' (that is the pod's own localhost, not the node)" ;; esac
ip -4 -o addr show | grep -qE " $HOSTSEEN/[0-9]+ " || { touch "$HOLD"; wait "$TP" 2>/dev/null || true; fail "$HOSTSEEN is not an address of the node"; }
sudo ss -ltnpH "sport = :$PORTSEEN" | grep -q docker-proxy || { touch "$HOLD"; wait "$TP" 2>/dev/null || true; fail "no docker-proxy of the node listens on port $PORTSEEN"; }
echo "  -> OK (host $HOSTSEEN, port $PORTSEEN; node IP $NODEIP)"
touch "$HOLD"
wait "$TP" && RC=0 || RC=$?
[ "$RC" = "0" ] || fail "the test failed after starting the container (exit status $RC): $(grep -v '^\[main\]' "$OUT" | tail -3 | cut -c1-300 | tr '\n' ' ')"
grep -qx "ANSWER bench71379578-ready nonce=$NONCE" "$OUT" && grep -qx DONE "$OUT" || fail "the test did not get the answer of its container (with this run's nonce) over the published port, or did not finish"

echo "[oracle] and the test's own cleanup: its container is gone from the node's containerd..."
for ns in $(ctr namespaces ls -q); do
    ! ctr -n "$ns" containers ls -q | grep -qxF "$CID" || fail "the container of the test is still in the node's containerd (namespace $ns)"
done
echo "  -> OK"
echo "[oracle] all checks passed."
