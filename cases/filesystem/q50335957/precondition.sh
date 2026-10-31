#!/bin/bash
# Precondition: the lab is as setup.sh left it (runc, its wrapper, the rootfs and the bundle's config.json unchanged); the bundle as it is does NOT start (the question's error: mounting the host's /proc at /test-proc
# with rbind,ro gives "operation not permitted"); a copy of it that only adds the three flags the mount has (nosuid,nodev,noexec) starts, so the lab itself works. Runs two short containers and removes them.
CASE_ID="bench50335957"
LIB="/var/lib/$CASE_ID"
BUNDLE="$LIB/bundle"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
RUNC="$LIB/bin/runc"
fail() { echo "[precondition] FAIL: $*"; exit 1; }

[ -n "$(sudo cat "$STATE_DIR/ready" 2>/dev/null)" ] || fail "setup.sh has not run"
sudo sh -c "cd / && sha256sum -c --quiet '$STATE_DIR/lab.sha' && sha256sum -c --quiet '$STATE_DIR/rootfs.sha' && sha256sum -c --quiet '$STATE_DIR/config.sha'" >/dev/null 2>&1 || fail "the lab or the bundle's config.json is not as setup.sh left it"
"$LIB/runc" --version | grep -q 'runc version 1.1.12' || fail "runc is not 1.1.12"

mkdir -p "$WORK_DIR/pre/a" "$WORK_DIR/pre/b"
python3 - "$BUNDLE/config.json" "$WORK_DIR/pre" <<'PY' || fail "could not derive the two test bundles"
import json, sys
c = json.load(open(sys.argv[1])); d = sys.argv[2]
c["root"]["path"] = "/var/lib/bench50335957/bundle/rootfs"
c["linux"]["cgroupsPath"] = "/bench50335957/pre"
json.dump(c, open(d + "/a/config.json", "w"))
for m in c["mounts"]:
    if m["destination"] == "/test-proc":
        m["options"] = ["rbind", "ro", "nosuid", "nodev", "noexec"]
json.dump(c, open(d + "/b/config.json", "w"))
PY

# the bundle as it is
sudo timeout -k 3 30 "$RUNC" run -d --pid-file "$WORK_DIR/pre/a.pid" -b "$WORK_DIR/pre/a" pre-a </dev/null >"$WORK_DIR/pre/a.out" 2>&1
rc=$?
sudo timeout -k 3 20 "$RUNC" delete -f pre-a >/dev/null 2>&1
[ "$rc" -ne 0 ] || fail "the bundle as it is starts (the symptom is not there)"
grep -q 'error mounting .*/proc.* to rootfs at .*/test-proc' "$WORK_DIR/pre/a.out" && grep -q 'operation not permitted' "$WORK_DIR/pre/a.out" \
    || fail "the bundle fails, but not with the mount error of the question: $(tail -c 300 "$WORK_DIR/pre/a.out")"

# the same with the three flags added: starts, with the host's /proc read-only at /test-proc
sudo timeout -k 3 30 "$RUNC" run -d --pid-file "$WORK_DIR/pre/b.pid" -b "$WORK_DIR/pre/b" pre-b </dev/null >"$WORK_DIR/pre/b.out" 2>&1
rc=$?
ok=0
for _ in $(seq 1 50); do grep -q READY "$WORK_DIR/pre/b.out" 2>/dev/null && { ok=1; break; }; sleep 0.2; done
pid=$(sudo cat "$WORK_DIR/pre/b.pid" 2>/dev/null)
mi=$(sudo grep ' /test-proc ' "/proc/$pid/mountinfo" 2>/dev/null)
sudo timeout -k 3 20 "$RUNC" delete -f pre-b >/dev/null 2>&1
[ "$rc" -eq 0 ] && [ "$ok" = 1 ] || fail "even with the three flags added the container does not start: $(tail -c 300 "$WORK_DIR/pre/b.out")"
echo "$mi" | grep -qE ' /test-proc ro[, ]' || fail "with the flags the /test-proc mount is not read-only: $mi"
sudo rm -rf "$WORK_DIR/pre"
echo "[precondition] PASS: the bundle as it is fails with 'error mounting \"/proc\" to rootfs at \"/test-proc\" ... operation not permitted'; the same with nosuid,nodev,noexec added starts"
