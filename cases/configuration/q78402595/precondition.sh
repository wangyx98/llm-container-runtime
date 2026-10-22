#!/bin/bash
set -e

CASE_ID="bench78402595"
LIB_BASE="/var/lib/$CASE_ID"
CTR="$LIB_BASE/bin/ctr"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
LIM=/proc/sys/net/core/bpf_jit_limit
. "$STATE_DIR/calib.env"
case "$(uname -m)" in x86_64) WANT="1.5.7" ;; *) WANT="1.6.0" ;; esac

fail() { echo "[precondition] FAIL: $*"; exit 1; }
count_hold() { local n=0 p; for p in /proc/[0-9]*; do [ "$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")" = "/app hold " ] && n=$((n + 1)); done; echo $n; }

echo "[precondition] the lab: private containerd $WANT, the container tgt with the default seccomp profile..."
sudo "$LIB_BASE/bin/containerdctl" status >/dev/null || fail "containerd of the lab is not running"
sudo "$CTR" version | grep -q "Version:  v$WANT" || fail "containerd is not $WANT: $(sudo "$CTR" version | tr '\n' ' ')"
INIT=$(sudo "$CTR" tasks ls | awk '$1=="tgt" && $3=="RUNNING" {print $2}')
[ -n "$INIT" ] || fail "the container tgt does not run"
grep -q '^Seccomp:[[:space:]]*2' "/proc/$INIT/status" || fail "the container's first process has no seccomp filter"
echo "  containerd v$WANT, tgt running (first process $INIT, seccomp filter mode 2)"

echo "[precondition] the leftovers and the limit..."
N=$(count_hold)
[ "$N" = "$LEAKS" ] || fail "$N leftover '/app hold' processes (expected $LEAKS)"
CUR=$(sudo cat $LIM); DEF=$(cat "$LIB_BASE/default_bpf_jit_limit")
[ "$CUR" = "$T" ] || fail "net.core.bpf_jit_limit is $CUR, expected $T"
[ "$CUR" -lt "$DEF" ] || fail "the limit $CUR is not below the default $DEF"
echo "  $N leftover processes in the container, net.core.bpf_jit_limit = $CUR (the machine's default is $DEF)"

echo "[precondition] the exec of the question: 'ctr tasks exec tgt /app probe' fails with errno 524, every time..."
for i in 1 2 3; do
    OUT=$(sudo "$CTR" tasks exec --exec-id "pre$i" tgt /app probe 2>&1) && fail "an exec worked under the limit $CUR: $OUT"
    echo "$OUT" | grep -q "error loading seccomp filter into kernel: error loading seccomp filter: errno 524" || fail "the exec failed with another error: $OUT"
done
echo "  exec failed 3 times: $(echo "$OUT" | grep -o 'unable to init seccomp.*' | head -1)"

echo "[precondition] control: with the limit at the default the same exec works and the profile forbids the new user namespace..."
trap 'sudo sh -c "echo $CUR > $LIM"' EXIT
sudo sh -c "echo $DEF > $LIM"
OUT=$(sudo "$CTR" tasks exec --exec-id pre9 tgt /app probe 2>&1) || fail "the exec fails although the limit is the default: $OUT"
echo "$OUT" | grep -q "probe seccomp=2 userns_rc=-1 userns_errno=1" || fail "the probe does not show the profile: $OUT"
sudo sh -c "echo $CUR > $LIM"
trap - EXIT
[ "$(sudo cat $LIM)" = "$CUR" ] || fail "the limit could not be put back"
echo "  default limit: $OUT"

echo "[precondition] OK: the exec fails only because the JIT memory limit is used up (errno 524); the leftovers and the limit are as recorded"
