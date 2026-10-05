#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75533491"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
SCRIPT_FILE="$WORK_DIR/get_container_id.sh"

# shellcheck disable=SC1091
. "$STATE_DIR/lib.sh"

echo "[oracle] check 1: containerd must be up and the three containers must still run, unchanged..."
if ! sudo ctr version >/dev/null 2>&1; then
    echo "  -> FAIL: containerd does not answer"
    exit 1
fi
while read -r style id; do
    if ! sudo ctr -n default tasks ls 2>/dev/null | awk -v n="$id" '$1==n && $3=="RUNNING"' | grep -q .; then
        echo "  -> FAIL: container $id ($style) is not running any more (the containers must not be touched)"
        exit 1
    fi
done < "$STATE_DIR/containers"
N=$(sudo ctr -n default containers ls -q "labels.$CASE_ID==1" 2>/dev/null | wc -l)
if [ "$N" != 3 ]; then
    echo "  -> FAIL: $N containers carry this case's label, expected the original 3"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: $SCRIPT_FILE must exist and not be empty..."
if ! sudo test -f "$SCRIPT_FILE"; then
    echo "  -> FAIL: $SCRIPT_FILE does not exist"
    exit 1
fi
if ! sudo test -s "$SCRIPT_FILE"; then
    echo "  -> FAIL: $SCRIPT_FILE is empty"
    exit 1
fi
SCRIPT=$(sudo cat "$SCRIPT_FILE")
echo "  -> OK"

# run_in ID LABEL: run the script inside the container; print the verdict line, return 1 if wrong
run_in() {
    local id="$1" label="$2" out rc lines got
    out=$(cexec "$id" "$SCRIPT") && rc=0 || rc=$?
    lines=$(printf '%s\n' "$out" | grep -c . || true)
    got=$(printf '%s' "$out" | tr -d '[:space:]')
    if [ "$lines" -eq 1 ] && [ "$got" = "$id" ]; then
        echo "  -> OK ($label: printed the container's ID)"
        return 0
    fi
    if [ "$lines" -eq 0 ]; then
        echo "  -> FAIL: in the $label container (${id:0:12}...) the script printed nothing (exit code $rc)"
    elif [ "$lines" -gt 1 ]; then
        echo "  -> FAIL: in the $label container (${id:0:12}...) the script printed $lines lines, expected exactly one"
    else
        echo "  -> FAIL: in the $label container (${id:0:12}...) the script printed '${got:0:100}', expected ${id}"
    fi
    return 1
}

echo "[oracle] check 3: run in each of the three containers, the script must print that container's ID"
echo "[oracle]          and nothing else..."
FAILED=0
while read -r style id; do
    run_in "$id" "$style" || FAILED=1
done < "$STATE_DIR/containers"
[ "$FAILED" = 0 ] || exit 1

# a container the solution has never seen: the script cannot know its ID from a table
echo "[oracle] check 4: run in a fourth container created now (new random ID), the script must print its ID..."
NEW_ID=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
make_container systemd "$NEW_ID" || { echo "  -> FAIL: (oracle problem) could not start the extra container"; exit 1; }
run_in "$NEW_ID" "extra" || exit 1

echo "[oracle] all checks passed."
