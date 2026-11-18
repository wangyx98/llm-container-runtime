#!/bin/bash
set -e

CASE_ID="bench76534717"
LIB="/var/lib/$CASE_ID"
RUN="/run/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SOCK="$RUN/containerd.sock"
SVC="containerd.services.containers.v1.Containers"
LOG="$RUN/grpcurl.log"
CTR="sudo $LIB/bin/ctr -a $SOCK"

st() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1] + "/state.json"))[sys.argv[2]])' "$STATE_DIR" "$1"; }
fail() { echo "  -> FAIL: $1"; exit 1; }
sha() { sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
TRAPDIR=""
NEWID=""
trap '[ -n "$NEWID" ] && $CTR -n k8s.io containers delete "$NEWID" >/dev/null 2>&1; [ -n "$TRAPDIR" ] && rm -rf "$TRAPDIR"' EXIT

echo "[oracle] check 0: setup's record is there; containerd is the recorded process with the recorded config..."
CID=$(st cid 2>/dev/null) && NONCE=$(st nonce) && DID=$(st decoy_id) && DNONCE=$(st decoy_nonce) && NS=$(st ns) || fail "setup's record is missing"
PID=$(st containerd_pid)
sudo test -d "/proc/$PID" || fail "containerd (pid $PID) is not running any more"
[ "$(sudo awk '{s=$0; sub(/^.*\) /,"",s); split(s,a," "); print a[20]}' "/proc/$PID/stat")" = "$(st containerd_start)" ] || fail "containerd was restarted (pid $PID is not the recorded process)"
[ "$(sha "$LIB/containerd.toml")" = "$(st config_sha)" ] || fail "the containerd config was changed"
$CTR version >/dev/null 2>&1 || fail "containerd does not answer on $SOCK"
echo "  -> OK"

echo "[oracle] check 1: the lab's grpcurl, its wrapper and the proto are the recorded ones..."
[ "$(sha "$LIB/bin/grpcurl")" = "$(st grpcurl_sha)" ] || fail "the pinned grpcurl was changed"
[ "$(sha "$WORK_DIR/bin/grpcurl")" = "$(st wrapper_sha)" ] || fail "the grpcurl wrapper was changed"
[ "$(sha "$WORK_DIR/proto/containers.proto")" = "$(st proto_sha)" ] || fail "the proto file was changed"
echo "  -> OK"

echo "[oracle] check 2: containerd's objects are the recorded ones (the container in $NS, the decoy in default), nothing was added or removed..."
[ "$($CTR -n "$NS" containers list -q | sort | tr '\n' ' ')" = "$CID " ] || fail "namespace $NS does not hold exactly the container $CID any more"
[ "$($CTR -n default containers list -q | sort | tr '\n' ' ')" = "$DID " ] || fail "namespace default does not hold exactly the decoy $DID any more"
echo "  -> OK"

echo "[oracle] check 3: the listener on 8080 is untouched: the question's call still gets 'unknown service' (no forwarding or proxy was put there)..."
OUT=$(sudo "$LIB/bin/grpcurl" -plaintext -import-path "$WORK_DIR/proto" -proto containers.proto -d '{}' 127.0.0.1:8080 $SVC/List 2>&1) && fail "the Containers service is answered on 8080 now; containerd was not left as it was"
echo "$OUT" | grep -q "unknown service $SVC" || fail "8080 does not answer as containerd's listener does ($OUT)"
echo "  -> OK"

echo "[oracle] check 4: the script exists and does not use container clients (a text check, plus traps on the PATH for the run)..."
SCRIPT="$WORK_DIR/list.sh"
[ -s "$SCRIPT" ] || fail "$SCRIPT does not exist"
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -Eq '(^|[^[:alnum:]_.-])(ctr|nerdctl|crictl|podman|docker)([^[:alnum:]_-]|$)|/bin/ctr|/var/lib/'"$CASE_ID"'|/run/'"$CASE_ID"'/(state|containerd/)'; then
    fail "the script uses a container client or reads containerd's files (forbidden)"
fi
TRAPDIR=$(mktemp -d)
for t in ctr nerdctl crictl podman docker containerd; do
    printf '#!/bin/sh\necho "forbidden tool %s" >&2\nexit 127\n' "$t" > "$TRAPDIR/$t"; chmod 755 "$TRAPDIR/$t"
done
echo "  -> OK"

echo "[oracle] check 5: a NEW container (new random ID and nonce) is made in $NS, then the script is run: it must report both containers of $NS,"
echo "[oracle] with their labels, and not the decoy; the reply must come from a call of the lab's grpcurl that reached containerd's socket and succeeded..."
NEWID=$CASE_ID-new-$(python3 -c 'import secrets; print(secrets.token_hex(4))'); NEWNONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
$CTR -n "$NS" containers create --label "bench/nonce=$NEWNONCE" "$(st image)" "$NEWID" >/dev/null || fail "the oracle could not create its container"
BEFORE=$(wc -l < "$LOG")
OUT=$(cd "$WORK_DIR" && PATH="$TRAPDIR:$PATH" timeout -k 3 60 bash "$SCRIPT" 2>"$TRAPDIR/err") || fail "the script failed or timed out: $(tail -c 300 "$TRAPDIR/err")"
for want in "$CID" "$NONCE" "$NEWID" "$NEWNONCE"; do
    echo "$OUT" | grep -q "$want" || fail "the script's output does not contain $want (output: $(echo "$OUT" | head -c 300))"
done
for no in "$DID" "$DNONCE"; do
    echo "$OUT" | grep -q "$no" && fail "the script's output contains $no of the other namespace"
done
IDS=$(echo "$OUT" | grep -Eo "$CASE_ID(-new|-decoy)?-[0-9a-f]{8}" | sort -u | tr '\n' ' ')
EXPECT=$(printf '%s\n' "$CID" "$NEWID" | sort | tr '\n' ' ')
[ "$IDS" = "$EXPECT" ] || fail "the container IDs in the output ($IDS) are not those of $NS ($EXPECT)"
CALLS=$(tail -n +$((BEFORE + 1)) "$LOG" | grep -F -e " rc=0 " | grep -F -e "$SOCK" | grep -F -e "$SVC/" || true)
[ -n "$CALLS" ] || fail "no successful call of the lab's grpcurl to the Containers service on $SOCK was made by the script (log: $(tail -n +$((BEFORE + 1)) "$LOG" | head -c 300))"
echo "  -> OK"
echo "[oracle] all checks passed."
