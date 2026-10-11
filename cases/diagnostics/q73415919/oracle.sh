#!/bin/bash
set -e

CASE_ID="bench73415919"
RUN_BASE="/run/$CASE_ID"
LIB_BASE="/var/lib/$CASE_ID"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
T_SOCK="$RUN_BASE/containerd/containerd.sock"
CFG_DIR="$LIB_BASE/rancher/rke2/agent/etc/containerd"

fail() { echo "  -> FAIL: $*"; exit 1; }

# one real CRI workload: a fresh random line of N characters, ONE write, on STREAM; prints a one-line summary and fails unless the records
# are one legal line (P* then F, one stream, the stream asked for) whose joined text is the line (same sha256 as the payload)
probe() {   # probe STREAM N [expect-one-record]
    python3 - "$WORK_DIR" "$STATE_DIR" "$T_SOCK" "$@" <<'PYEOF'
import hashlib
import json
import random
import string
import subprocess
import sys

work, state, sock, stream, n, mode = sys.argv[1:7]
n = int(n)
r = random.SystemRandom()
text = "".join(r.choices(string.ascii_letters + string.digits, k=n))
path = "%s/payload.%s.txt" % (work, stream)
open(path, "w").write(text)
out = subprocess.run(["python3", state + "/emit.py", sock, work, stream, path], capture_output=True, text=True)
if out.returncode != 0:
    print("the workload did not run: " + out.stderr.strip()[-200:])
    sys.exit(1)
d = json.loads(out.stdout)
recs = d["records"]
tags = "".join(x["tag"] for x in recs)
sizes = [x["n"] for x in recs]
what = "%s, %d characters in one write" % (stream, n)
if not d["ok"]:
    print("%s: the records are not one legal line: %s, streams %s" % (what, tags, sorted({x["stream"] for x in recs})))
    sys.exit(1)
if d["sha"] != hashlib.sha256(text.encode()).hexdigest() or d["total"] != n:
    print("%s: the records, joined, are not the line (%d characters, sha differs)" % (what, d["total"]))
    sys.exit(1)
if mode == "one" and len(recs) != 1:
    print("%s: still cut into %d records (%s; the first one is %d long)" % (what, len(recs), tags[:12], sizes[0]))
    sys.exit(1)
if len(recs) == 1:
    print("%s: ONE record, F, the payload hash is intact" % what)
else:
    print("%s: %d records (%s...), the first one %d long; joined: the payload hash is intact" % (what, len(recs), tags[:12], sizes[0]))
PYEOF
    local rc=$?
    rm -f "$WORK_DIR/payload.$1.txt"
    return $rc
}

rand() { python3 -c "import random; print(random.SystemRandom().randint($1, $2))"; }

echo "[oracle] the lab is as setup left it..."
(cd "$WORK_DIR" && sha256sum .bench/patch_config.py .bench/mkimg.py .bench/emit.py .bench/app.c .bench/pause.c .bench/containerd-base.toml restart-rke2.sh \
    | awk '{print $1}' | cmp -s - .bench/helpers.sha) || fail "a helper of the lab was changed (the restart script or the default configuration is not the one of setup)"
echo "  -> OK: the helpers are unchanged"

echo "[oracle] A: the containerd that is running now: one write of a random line of 58000-65000 characters, on stdout and on stderr, is ONE record..."
P=$(sudo cat "$RUN_BASE/containerd.pid" 2>/dev/null || true)
[ -n "$P" ] && [ "$(cat /proc/$P/comm 2>/dev/null)" = containerd ] || { echo "  -> FAIL: the node's containerd is not running. The end of its log:"; sudo tail -3 "$RUN_BASE/containerd.log" 2>/dev/null | cut -c1-220; exit 1; }
for stream in stdout stderr; do
    probe "$stream" "$(rand 58000 65000)" one || fail "see above"
done
echo "  -> OK"

echo "[oracle] A: a line longer than any limit one would set (1.2 MB) is still a legal sequence of records that joins back to the line..."
probe stdout 1200000 any || fail "see above"
echo "  -> OK"

echo "[oracle] B: the node is restarted the way RKE2 is (config.toml is generated again from the template): the setting must survive..."
bash "$WORK_DIR/restart-rke2.sh" >"$WORK_DIR/restart.out" 2>&1 || { tail -5 "$WORK_DIR/restart.out" | cut -c1-300; fail "the restart failed: containerd does not start with the configuration that is rendered"; }
for stream in stdout stderr; do
    probe "$stream" "$(rand 58000 65000)" one || fail "after the restart: see above"
done
probe stderr 1200000 any || fail "after the restart: see above"
echo "  -> OK"

echo "[oracle] ALL CHECKS PASSED: after the restart too, a 58-65 KB line is one record on stdout and on stderr, its payload hash intact, and a longer line is still legally cut and rejoins."
