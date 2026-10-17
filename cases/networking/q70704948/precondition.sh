#!/bin/bash
set -e

CASE_ID="bench70704948"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup left them; the VM runs..."
sudo test -s "$STATE_DIR/truth.json" || fail "setup did not leave its record"
sudo bash -c 'cd "$1" && sha256sum netcfg.py dns.py dist.py mkproject.py mkbase.py patch_config.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper changed"
echo "  -> OK"

echo "[precondition] the build containers and the containers of nerdctl run have different name servers; the controls: nerdctl run downloads the distribution, a build container that is given the"
echo "               address of the download site downloads it too; the build of the project fails with 'Could not resolve host' (a few seconds each)..."
sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "see above"

echo "[precondition] ALL CHECKS PASSED: the build of the project fails because the build container cannot resolve the name of the download site, while a container of nerdctl run resolves and downloads it."
