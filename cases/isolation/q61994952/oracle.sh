#!/bin/bash
set -e

WORK_DIR="/tmp/bench61994952"
VERDICT_FILE="$WORK_DIR/verdict.json"
GROUND_TRUTH_FILE="$WORK_DIR/ground_truth.json"

echo "[oracle] check 0: verdict.json must exist and be valid, non-empty JSON..."
if [ ! -f "$VERDICT_FILE" ]; then
    echo "  -> FAIL: $VERDICT_FILE was not written by the solution"
    exit 1
fi
python3 -c "
import json
with open('$VERDICT_FILE') as f:
    data = json.load(f)
assert isinstance(data, dict) and data, 'verdict.json must be a non-empty JSON object'
"
echo "  -> OK"

echo "[oracle] check 1: comparing the solution's verdicts against the real,"
echo "[oracle]          randomized-per-run ground truth (never seen by the"
echo "[oracle]          solution as a labeled field -- it had to genuinely"
echo "[oracle]          inspect each container's state.json)..."
sudo python3 -c "
import json

with open('$VERDICT_FILE') as f:
    verdicts = json.load(f)
with open('$GROUND_TRUTH_FILE') as f:
    truth = json.load(f)

VALID = {'PRIVILEGED', 'NOT_PRIVILEGED'}
errors = []
for name, expected in truth.items():
    got = str(verdicts.get(name, '')).strip().upper()
    if got not in VALID:
        errors.append(f'{name}: invalid/missing verdict {verdicts.get(name)!r} (expected {expected})')
    elif got != expected:
        errors.append(f'{name}: got {got}, expected {expected}')

if errors:
    print('MISMATCHES:')
    for e in errors:
        print(' -', e)
    raise SystemExit(1)

print('all', len(truth), 'containers classified correctly:')
for name, expected in truth.items():
    print(f'  {name}: {expected}')
"
if [ $? -ne 0 ]; then
    echo "  -> FAIL: one or more containers were misclassified (see above)"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2 (anti-cheat): a literal grep for the word 'privileged'"
echo "[oracle]          must find NOTHING in any of the 4 real state.json"
echo "[oracle]          files -- this proves the field genuinely doesn't"
echo "[oracle]          exist, so any correct verdict above could not have"
echo "[oracle]          come from grepping for that word..."
RUNC_ROOT="$WORK_DIR/runc-root"
if sudo grep -ril "privileged" "$RUNC_ROOT" 2>/dev/null | grep -q .; then
    echo "  -> FAIL: the word 'privileged' unexpectedly appears in runc state"
    echo "     -- the premise of this task (that it never does) does not hold"
    exit 1
fi
echo "  -> OK (confirms the classification had to come from real signal"
echo "         inspection, not a keyword match)"

echo "[oracle] ALL CHECKS PASSED"
