#!/bin/bash
# Precondition oracle: the lab is the one setup.sh recorded and the question's symptom is there: the engineer's Go program only pulls (an image that no
# registry has), while BuildKit, which can build the Dockerfile, works. The oracle itself is the control: it must FAIL while the program is the starter.
CASE_ID="bench66733729"
LIB_BASE="/var/lib/$CASE_ID"
RUN_BASE="/run/$CASE_ID"
STATE_DIR="/tmp/$CASE_ID/.bench"
CTL="$LIB_BASE/bin"
APP_DIR="$LIB_BASE/app"
DEMO_DIR="$LIB_BASE/demo"
NS="bench66733729"
REF="docker.io/library/bench66733729-app:1"

fail() { echo "[precondition] FAIL: $*"; exit 1; }
step() { echo "[precondition] $*"; }
ctr() { sudo "$CTL/ctr" "$@" 2> >(grep -v DEPRECATION >&2); }

[ -s "$STATE_DIR/files.sha" ] || fail "$STATE_DIR/files.sha is missing: setup.sh has not run"

step "1/4 the machine: containerd and buildkitd run, the files of the machine are as recorded, BuildKit has one containerd worker in its own namespace..."
for n in containerd buildkitd; do
    pid="$(cat "$RUN_BASE/$n.pid" 2>/dev/null)"
    [ -n "$pid" ] && sudo kill -0 "$pid" 2>/dev/null || fail "$n is not running"
done
( cd "$LIB_BASE" && sudo sha256sum -c "$STATE_DIR/files.sha" >/dev/null 2>&1 ) || fail "a file of the machine (script, configuration, program, demo context) differs from the record"
workers="$(sudo "$CTL/buildctl" debug workers --format '{{json .}}' 2>/dev/null)"
[ "$(echo "$workers" | grep -c .)" = 1 ] || fail "BuildKit does not have exactly one worker: $workers"
echo "$workers" | grep -q '"org.mobyproject.buildkit.worker.executor":"containerd"' || fail "the worker of BuildKit is not a containerd worker"
echo "$workers" | grep -q '"org.mobyproject.buildkit.worker.containerd.namespace":"buildkit"' || fail "the worker of BuildKit does not use the containerd namespace buildkit"
echo "  -> OK (containerd worker, namespace buildkit)"

step "2/4 the control: BuildKit builds the engineer's Dockerfile (the backend works, the failure is in the program)..."
out="$(sudo "$CTL/buildctl" build --frontend dockerfile.v0 --local "context=$DEMO_DIR" --local "dockerfile=$DEMO_DIR" --output "type=oci,dest=$STATE_DIR/control.tar" 2>&1)" \
    || fail "BuildKit could not build the demo context: $(echo "$out" | tail -3)"
sudo tar -tf "$STATE_DIR/control.tar" index.json >/dev/null 2>&1 || fail "the control build made no OCI archive"
sudo rm -f "$STATE_DIR/control.tar"
echo "  -> OK"

step "3/4 the symptom: the engineer's program (the pull example) builds and fails, no image appears in the namespace $NS..."
T="$(mktemp -d "$STATE_DIR/pre.XXXXXX")"
cp -r "$APP_DIR/." "$T/" && rm -f "$T/app"
( cd "$T" && GOFLAGS=-mod=mod "$LIB_BASE/bin/go" build -o "$T/prog" . ) >"$T/build.log" 2>&1 || { tail -5 "$T/build.log"; fail "the engineer's program does not build"; }
out="$(sudo timeout 120 "$T/prog" -context "$DEMO_DIR" -tag "$REF" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "the program succeeded although it only pulls an image that does not exist"
echo "$out" | grep -q "bench66733729-app" || fail "the program failed for another reason than the pull of $REF: $out"
echo "  program: $(echo "$out" | head -1 | cut -c1-200)"
[ -z "$(ctr -n "$NS" images ls -q)" ] || fail "the namespace $NS already has images"
rm -rf "$T"
echo "  -> OK"

step "4/4 the oracle itself, as the control: it must FAIL while the program does not use the BuildKit client..."
out="$(bash "$(dirname "$0")/oracle.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "the oracle passes although the program only pulls"
echo "$out" | grep -q "BuildKit" || fail "the oracle failed for another reason than the missing BuildKit client: $(echo "$out" | tail -2)"
echo "  -> OK ($(echo "$out" | tail -1 | cut -c1-200))"

echo "[precondition] PASS - the program only pulls; BuildKit works but is not used; there is no image to run."
