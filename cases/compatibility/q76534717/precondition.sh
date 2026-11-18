#!/bin/bash
set -e

CASE_ID="bench76534717"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/containerd.sock"
SVC="containerd.services.containers.v1.Containers"
REAL="$LIB/bin/grpcurl"            # the pinned program itself: the precondition's calls do not go into the wrapper's log
CTR="sudo $LIB/bin/ctr -a $SOCK"

st() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1] + "/state.json"))[sys.argv[2]])' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }
sha() { sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

CID=$(st cid); NONCE=$(st nonce); DID=$(st decoy_id); DNONCE=$(st decoy_nonce); NS=$(st ns)

echo "[precondition] containerd is the recorded process, its config, the pinned grpcurl, the proto and the wrapper are unchanged..."
PID=$(st containerd_pid)
sudo test -d "/proc/$PID" || fail "the recorded containerd (pid $PID) is gone"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st containerd_start)" ] || fail "pid $PID is not the recorded containerd"
[ "$(sudo readlink "/proc/$PID/exe")" = "$LIB/bin/containerd" ] || fail "pid $PID does not run $LIB/bin/containerd"
[ "$(sha "$LIB/containerd.toml")" = "$(st config_sha)" ] || fail "the containerd config changed"
[ "$(sha "$REAL")" = "$(st grpcurl_sha)" ] || fail "the pinned grpcurl changed"
[ "$(sha "$WORK_DIR/bin/grpcurl")" = "$(st wrapper_sha)" ] || fail "the grpcurl wrapper changed"
[ "$(sha "$WORK_DIR/proto/containers.proto")" = "$(st proto_sha)" ] || fail "the proto changed"
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $SOCK"
echo "  -> OK"

echo "[precondition] what port 8080 is: a TCP listener of this very containerd (its log says so, and the socket belongs to the process)..."
grep -q 'address="127.0.0.1:8080"' "$RUN/containerd.log" || fail "containerd's log has no 'serving' line for 127.0.0.1:8080"
OWNER=$(sudo python3 - "$PID" <<'PYEOF'
import os, sys

pid = sys.argv[1]
inodes = set()
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    try:
        for line in open(f).read().splitlines()[1:]:
            c = line.split()
            if c[3] == "0A" and int(c[1].rsplit(":", 1)[1], 16) == 8080:
                inodes.add(c[9])
    except OSError:
        pass
for fd in os.listdir("/proc/%s/fd" % pid):
    try:
        t = os.readlink("/proc/%s/fd/%s" % (pid, fd))
    except OSError:
        continue
    if t.startswith("socket:[") and t[8:-1] in inodes:
        print("yes")
        break
PYEOF
)
[ "$OWNER" = yes ] || fail "the listener on port 8080 does not belong to containerd (pid $PID)"
echo "  -> OK"

echo "[precondition] the question's call, the Containers service on 127.0.0.1:8080 with the proto: 'Unimplemented: unknown service'..."
OUT=$(sudo "$REAL" -plaintext -import-path "$WORK_DIR/proto" -proto containers.proto -d '{}' 127.0.0.1:8080 $SVC/List 2>&1) && fail "the call on 8080 succeeded; the symptom of the question is not there"
echo "$OUT" | grep -q "Unimplemented" || fail "the call on 8080 did not fail with Unimplemented ($OUT)"
echo "$OUT" | grep -q "unknown service $SVC" || fail "the call on 8080 did not report 'unknown service $SVC' ($OUT)"
echo "  -> OK"

echo "[precondition] there is no reflection to ask what a server serves (the proto file is needed)..."
OUT=$(sudo "$REAL" -plaintext -unix "$SOCK" list 2>&1) && fail "the socket answers server reflection"
echo "$OUT" | grep -qi "reflection" || fail "unexpected answer to 'list' ($OUT)"
echo "  -> OK"

echo "[precondition] the objects are there (asked of containerd's own client): the container in '$NS', the decoy in 'default'..."
[ "$($CTR -n "$NS" containers list -q | sort | tr '\n' ' ')" = "$CID " ] || fail "namespace $NS does not hold exactly the container $CID"
[ "$($CTR -n default containers list -q | sort | tr '\n' ' ')" = "$DID " ] || fail "namespace default does not hold exactly the decoy $DID"
$CTR -n "$NS" containers info "$CID" | grep -q "$NONCE" || fail "the container has no nonce label"
echo "  -> OK"

echo "[precondition] control: the same service on the main unix socket with the namespace header works (the container, not the decoy);"
echo "[precondition] without the header containerd asks for the namespace; with namespace default only the decoy is listed..."
G="sudo $REAL -plaintext -unix -import-path $WORK_DIR/proto -proto containers.proto -d {}"
OUT=$($G -rpc-header "containerd-namespace: $NS" "$SOCK" $SVC/List 2>&1) || fail "the control call failed ($OUT)"
echo "$OUT" | grep -q "$CID" && echo "$OUT" | grep -q "$NONCE" || fail "the control call did not return the container and its nonce"
echo "$OUT" | grep -q "$DID" && fail "the control call returned the decoy of namespace default"
OUT=$($G "$SOCK" $SVC/List 2>&1) && fail "without the namespace header the call succeeded"
echo "$OUT" | grep -q "namespace is required" || fail "without the header the answer was not 'namespace is required' ($OUT)"
OUT=$($G -rpc-header "containerd-namespace: default" "$SOCK" $SVC/List 2>&1) || fail "the call for namespace default failed"
echo "$OUT" | grep -q "$DID" && ! echo "$OUT" | grep -q "$CID" || fail "namespace default does not list just the decoy"
echo "  -> OK"
echo "[precondition] all checks passed."
