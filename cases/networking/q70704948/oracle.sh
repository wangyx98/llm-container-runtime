#!/bin/bash
set -e

CASE_ID="bench70704948"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[oracle] the helpers are as setup left them..."
sudo test -s "$STATE_DIR/truth.json" || fail "the record of setup is gone"
sudo bash -c 'cd "$1" && sha256sum netcfg.py dns.py dist.py mkproject.py mkbase.py patch_config.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
echo "  -> OK"

echo "[oracle] the lab, an empty build cache, then 'nerdctl build' of the project (no cache): the distribution is downloaded by the build container, the artifact is checked, the control stays true..."
sudo python3 "$STATE_DIR/verify.py" "$WORK_DIR" || fail "see above"

echo "[oracle] ALL CHECKS PASSED: the project builds from an empty cache, the build container downloaded the pinned distribution through the corporate name server, the artifact is the expected one, and containers of nerdctl run still reach the download site."
