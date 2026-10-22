#!/bin/bash
set -e

CASE_ID="bench78402595"
LIB_BASE="/var/lib/$CASE_ID"
CTR="$LIB_BASE/bin/ctr"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
LIM=/proc/sys/net/core/bpf_jit_limit
MORE=12           # execs held at the same time by the check (the "probe runs" of a normal day; the limit of the lab leaves room for 15 more than the container alone)
PROBES=6          # execs of the target that must work while they are held
TAG="o$$"
case "$(uname -m)" in x86_64) WANT="1.5.7" ;; *) WANT="1.6.0" ;; esac

fail() { echo "[oracle] FAIL: $*"; exit 1; }
count_hold() { local n=0 p; for p in /proc/[0-9]*; do [ "$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")" = "/app hold " ] && n=$((n + 1)); done; echo $n; }
STARTED=0
release() { [ "$STARTED" = 1 ] || return 0; for i in $(seq 1 $MORE); do sudo "$CTR" tasks kill --exec-id "$TAG-$i" -s SIGKILL tgt >/dev/null 2>&1 || true; done; }
trap 'release; sudo sh -c "echo ${CUR:-$(sudo cat $LIM)} > $LIM"' EXIT

echo "[oracle] the lab is as it was: containerd $WANT, the container tgt with its profile and capabilities, the JIT settings of the host within the default..."
sudo "$LIB_BASE/bin/containerdctl" status >/dev/null || fail "containerd of the lab is not running"
sudo "$CTR" version | grep -q "Version:  v$WANT" || fail "containerd is not $WANT"
sudo "$CTR" containers info tgt > "$STATE_DIR/spec.now" 2>/dev/null || fail "the container tgt does not exist"
python3 - "$STATE_DIR/spec.json" "$STATE_DIR/spec.now" <<'PYEOF' || fail "the container tgt is not the one of the lab (image, seccomp profile, capabilities or user changed)"
import json
import sys

want = json.load(open(sys.argv[1]))
d = json.load(open(sys.argv[2]))
spec = d["Spec"]
sec = spec.get("linux", {}).get("seccomp") or {}
caps = spec["process"].get("capabilities", {})
got = {"image": d["Image"], "seccomp_default": sec.get("defaultAction"), "seccomp_rules": len(sec.get("syscalls", [])),
       "bounding": sorted(caps.get("bounding", [])), "effective": sorted(caps.get("effective", [])),
       "no_new_privileges": spec["process"].get("noNewPrivileges", False), "user": spec["process"].get("user")}
sys.exit(0 if got == want else 1)
PYEOF
INIT=$(sudo "$CTR" tasks ls | awk '$1=="tgt" && $3=="RUNNING" {print $2}')
[ -n "$INIT" ] || fail "the container tgt does not run"
grep -q '^Seccomp:[[:space:]]*2' "/proc/$INIT/status" || fail "the first process of tgt has no seccomp filter (the profile is gone)"
CUR=$(sudo cat $LIM); DEF=$(cat "$LIB_BASE/default_bpf_jit_limit")
[ "$CUR" -le "$DEF" ] || fail "net.core.bpf_jit_limit is $CUR, above the machine's default $DEF: a bigger number is not a fix"
. "$STATE_DIR/calib.env"
for k in bpf_jit_enable bpf_jit_harden; do
    [ "$(sudo cat /proc/sys/net/core/$k)" = "$(sudo cat "$LIB_BASE/orig.$k")" ] || fail "net.core.$k was changed"
done
echo "  tgt runs with its profile (first process $INIT, seccomp mode 2), limit $CUR (default $DEF)"

echo "[oracle] the memory held by the leftover processes is released..."
N=$(count_hold)
[ "$N" = 0 ] || fail "$N processes ('/app hold') of old probe runs still hold their seccomp filters: the JIT memory is not released"
echo "  no leftover process"

echo "[oracle] the same pressure again, whatever limit the solution left: the limit of the lab ($T) is put back for the check, $MORE execs are held at once, and the target exec ($PROBES times) still works with the profile in force..."
sudo sh -c "echo $T > $LIM"
STARTED=1
for i in $(seq 1 $MORE); do
    OUT=$(sudo "$CTR" tasks exec -d --exec-id "$TAG-$i" tgt /app hold 2>&1) || fail "the held exec $i could not start: $(echo "$OUT" | tail -1)"
done
N=$(count_hold)
[ "$N" = "$MORE" ] || fail "$N of $MORE held execs run"
for i in $(seq 1 $PROBES); do
    OUT=$(sudo "$CTR" tasks exec --exec-id "$TAG-p$i" tgt /app probe 2>&1) || fail "target exec $i failed under the pressure: $(echo "$OUT" | tail -1)"
    echo "$OUT" | grep -qx "probe seccomp=2 userns_rc=-1 userns_errno=1" || fail "target exec $i ran without the profile or did not forbid the user namespace: $OUT"
done
echo "  $MORE held execs and $PROBES target execs: $OUT"

echo "[oracle] the held execs end and give the memory back; the limit is put back to what the solution left..."
release
sudo sh -c "echo $CUR > $LIM"
for i in $(seq 1 20); do [ "$(count_hold)" = 0 ] && break; sleep 0.5; done
[ "$(count_hold)" = 0 ] || fail "held execs do not end"
trap - EXIT

echo "[oracle] PASS: no leftover holds a filter, the exec of the question works under the limit of the lab with the seccomp profile and capabilities unchanged, the limit left is not above the default"
