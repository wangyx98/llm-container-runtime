#!/bin/bash
set -e

CONTAINER="bench62887953"
BUNDLE_DIR="/tmp/bench62887953/bundle"
CONFIG="$BUNDLE_DIR/config.json"
SENTINEL_UID="918273645"

sudo runc delete -f "${CONTAINER}-oracle-a" 2>/dev/null || true
sudo runc delete -f "${CONTAINER}-oracle-b" 2>/dev/null || true

echo "[oracle] check 0: LD_PRELOAD must be a real env entry, not smuggled into args..."
sudo python3 - "$CONFIG" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
env = cfg.get("process", {}).get("env", []) or []
args = cfg.get("process", {}).get("args", []) or []

has_ld_preload_env = any(e.startswith("LD_PRELOAD=/preload.so") for e in env)
if not has_ld_preload_env:
    print("FAIL: no LD_PRELOAD=/preload.so entry found in process.env")
    sys.exit(1)

for a in args:
    if "LD_PRELOAD" in a:
        print(f"FAIL: LD_PRELOAD found inside args ({a!r}) instead of env")
        sys.exit(1)
    if " " in a.strip():
        print(f"FAIL: args element {a!r} looks like a merged shell-style string, not a clean argv entry")
        sys.exit(1)
print("OK")
PYEOF
echo "  -> OK"

echo "[oracle] check 1: running the container (as the LLM's fix left it) must"
echo "[oracle]          exit 0 and print the PRELOADED sentinel uid ($SENTINEL_UID)..."
RUN_A_LOG="/tmp/bench62887953_oracle_run_a.log"
rm -f "$RUN_A_LOG"
# Redirect to a FILE rather than capturing with $(...): command substitution
# waits for EOF on its pipe, which can hang if any descendant process
# (runc's own re-exec'd init stage, a lingering namespace/cgroup helper,
# etc.) inherits the pipe's write end without closing it -- even after the
# container's actual process has exited. A plain file redirect has no such
# hazard: bash only waits for the direct child (runc) to exit.
set +e
sudo runc run --bundle "$BUNDLE_DIR" "${CONTAINER}-oracle-a" > "$RUN_A_LOG" 2>&1
RUN_A_STATUS=$?
set -e
sudo runc delete -f "${CONTAINER}-oracle-a" 2>/dev/null || true
RUN_A_OUT=$(cat "$RUN_A_LOG")
rm -f "$RUN_A_LOG"
echo "  -> output: $RUN_A_OUT"
if [ "$RUN_A_STATUS" -ne 0 ]; then
    echo "  -> FAIL: container exited with status $RUN_A_STATUS"
    exit 1
fi
if [ "$RUN_A_OUT" != "uid=$SENTINEL_UID" ]; then
    echo "  -> FAIL: expected 'uid=$SENTINEL_UID', got '$RUN_A_OUT'"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2 (anti-cheat): the sentinel must genuinely come from"
echo "[oracle]          LD_PRELOAD, not be hardcoded regardless of it. Re-running"
echo "[oracle]          the SAME bundle with LD_PRELOAD stripped back out of env"
echo "[oracle]          must go back to printing the REAL uid (0)..."
sudo cp "$CONFIG" "$CONFIG.oracle-backup"
sudo python3 - "$CONFIG" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
env = cfg.get("process", {}).get("env", []) or []
cfg["process"]["env"] = [e for e in env if not e.startswith("LD_PRELOAD=")]
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

RUN_B_LOG="/tmp/bench62887953_oracle_run_b.log"
rm -f "$RUN_B_LOG"
set +e
sudo runc run --bundle "$BUNDLE_DIR" "${CONTAINER}-oracle-b" > "$RUN_B_LOG" 2>&1
RUN_B_STATUS=$?
set -e
sudo runc delete -f "${CONTAINER}-oracle-b" 2>/dev/null || true
RUN_B_OUT=$(cat "$RUN_B_LOG")
rm -f "$RUN_B_LOG"

echo "[oracle] restoring the LLM's config.json exactly as it was left..."
sudo mv "$CONFIG.oracle-backup" "$CONFIG"

echo "  -> output without LD_PRELOAD: $RUN_B_OUT"
if [ "$RUN_B_STATUS" -ne 0 ]; then
    echo "  -> FAIL: container without LD_PRELOAD exited with status $RUN_B_STATUS (expected clean exit)"
    exit 1
fi
if [ "$RUN_B_OUT" != "uid=0" ]; then
    echo "  -> FAIL: expected the REAL uid (0) once LD_PRELOAD is removed, got '$RUN_B_OUT'."
    echo "     This means the sentinel value in check 1 was NOT actually coming from"
    echo "     LD_PRELOAD/preload.so -- the binary or output was hardcoded/faked instead."
    exit 1
fi
echo "  -> OK (output correctly reverts to the real uid once LD_PRELOAD is removed,"
echo "         proving the sentinel in check 1 genuinely came from the preloaded library)"

echo "[oracle] ALL CHECKS PASSED"
