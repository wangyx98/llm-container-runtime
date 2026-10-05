#!/bin/bash
set -e

SOCK="/run/containerd/containerd.sock"
CASE_ID="bench75009921"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
OUT="$WORK_DIR/containers.txt"
TRIPWIRE_EPOCH=946684800

# This check has to come before anything below runs ctr itself.
echo "[oracle] check 0: ctr, nerdctl and crictl must not have been run by the solution..."
if [ "$(cat "$STATE_DIR/tripwire_ok" 2>/dev/null)" = 1 ]; then
    while read -r b; do
        [ -n "$b" ] || continue
        AT=$(sudo stat -c %X "$b" 2>/dev/null || echo "$TRIPWIRE_EPOCH")
        if [ "$AT" != "$TRIPWIRE_EPOCH" ]; then
            echo "  -> FAIL: $b was run (the task rules out ctr, nerdctl and crictl)"
            exit 1
        fi
    done < "$STATE_DIR/tripwire_bins"
    echo "  -> OK"
else
    echo "  -> skipped (access times are not recorded on this machine)"
fi

echo "[oracle] check 1: containerd must be up and still hold exactly the containers it held before..."
if ! sudo ctr version >/dev/null 2>&1; then
    echo "  -> FAIL: containerd does not answer"
    exit 1
fi
LIVE=$(for ns in $(sudo ctr namespaces ls -q 2>/dev/null); do
    for c in $(sudo ctr -n "$ns" containers ls -q 2>/dev/null); do
        echo "$ns $c"
    done
done | LC_ALL=C sort)
if [ "$LIVE" != "$(cat "$STATE_DIR/containers.truth")" ]; then
    echo "  -> FAIL: the containers of containerd were changed (created, deleted or moved)"
    echo "     before: $(tr '\n' ',' < "$STATE_DIR/containers.truth")"
    echo "     now:    $(echo "$LIVE" | tr '\n' ',')"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 2: $OUT must exist and not be empty..."
if ! sudo test -f "$OUT"; then
    echo "  -> FAIL: $OUT does not exist"
    exit 1
fi
if ! sudo test -s "$OUT"; then
    echo "  -> FAIL: $OUT is empty"
    exit 1
fi
echo "  -> OK"

echo "[oracle] check 3: every line must be '<namespace> <container id>', no blank or other lines, no"
echo "[oracle]          repeated line..."
echo "[oracle] check 4: the lines must be exactly the containers of containerd (namespace and ID), none"
echo "[oracle]          missing, none extra..."
sudo cat "$OUT" > "$STATE_DIR/answer.txt"
python3 - "$STATE_DIR/answer.txt" "$STATE_DIR/containers.truth" <<'PYEOF'
import re
import sys

answer = open(sys.argv[1], errors="replace").read().split("\n")
truth = set(l for l in open(sys.argv[2]).read().split("\n") if l)

if answer and answer[-1] == "":
    answer.pop()                       # the newline that ends the last line
bad = [l for l in answer if not re.fullmatch(r"[^\s]+ [^\s]+", l)]
if bad:
    print("  -> FAIL: %d line(s) are not '<namespace> <container id>': %r" % (len(bad), bad[:3]))
    sys.exit(1)
dups = sorted(set(l for l in answer if answer.count(l) > 1))
if dups:
    print("  -> FAIL: repeated line(s): %r" % dups[:3])
    sys.exit(1)
print("  -> OK (%d lines)" % len(answer))

got = set(answer)
missing = sorted(truth - got)
extra = sorted(got - truth)
if missing or extra:
    if missing:
        print("  -> FAIL: %d container(s) missing from the file: %s" % (len(missing), ", ".join(missing[:6])))
    if extra:
        print("  -> FAIL: %d line(s) that are no container: %s" % (len(extra), ", ".join(extra[:6])))
    sys.exit(1)
print("  -> OK (all %d containers listed, nothing else)" % len(truth))
PYEOF
echo "[oracle] all checks passed."
