#!/bin/bash
set -e

CASE_ID="bench54365253"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_BASE="/var/lib/$CASE_ID"
DEMO_DIR="$LIB_BASE/demo"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"

fail() { echo "  -> FAIL: $*"; exit 1; }

sudo test -f "$STATE_DIR/truth.env" || fail "the record of the lab is missing (setup did not run)"
eval "$(sudo cat "$STATE_DIR/truth.env")"

echo "[precondition] the lab as recorded: the probe unchanged, the compose file of one service with its data, a bundle that is a plain 'runc spec', a converter that is a stub..."
sudo sh -c "cd / && sha256sum -c \"$STATE_DIR/files.sha\"" >/dev/null 2>&1 || fail "the probe in the master root file system differs from the record"
python3 - "$DEMO_DIR/docker-compose.yml" <<'PY' || fail "the compose file of the demo is not as expected"
import sys, yaml
svcs = yaml.safe_load(open(sys.argv[1]))["services"]
assert len(svcs) == 1
s = list(svcs.values())[0]
assert s["hostname"] == "bench-demo" and s["read_only"] is True and s["working_dir"] == "/srv/app" and s["command"][0] == "/probe" and len(s["volumes"]) == 2
PY
[ -s "$DEMO_DIR/data/config.txt" ] || fail "the data file is missing"
python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); assert c["process"]["args"] == ["sh"] and c["hostname"] == "runc"' "$DEMO_DIR/bundle/config.json" || fail "the bundle of the demo is not the plain default of runc spec"
OUT="$("$LIB_BASE/compose2oci" "$DEMO_DIR/docker-compose.yml" "$DEMO_DIR/bundle" 2>&1)" && fail "the converter worked before anything was done"
echo "$OUT" | grep -q "not implemented" || fail "the converter is not the stub"
echo "  -> OK"

echo "[precondition] the symptom: runc runs a bundle but not a compose file; the bundle that exists (default config.json made runnable) runs the probe with the hostname 'runc', not the compose file's, and none of its environment or mounts..."
T="$(mktemp -d "$WORK_DIR/pre-XXXXXX")"
mkdir "$T/bundle"
sudo cp -a "$STATE_DIR/rootfs" "$T/bundle/rootfs"
python3 - "$DEMO_DIR/bundle/config.json" "$T/bundle/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["process"]["terminal"] = False
c["process"]["args"] = ["/probe", "--hash", "/etc/app/config.txt"]
json.dump(c, open(sys.argv[2], "w"))
PY
sudo sh -c 'exec timeout -k 5 60 runc --root "$1" run --bundle "$2" bench54365253-pre >"$3" 2>&1 </dev/null' _ "/run/$CASE_ID" "$T/bundle" "$T/run.out" || { tail -3 "$T/run.out"; sudo runc --root "/run/$CASE_ID" delete -f bench54365253-pre >/dev/null 2>&1; fail "runc cannot run the control bundle"; }
sudo runc --root "/run/$CASE_ID" delete -f bench54365253-pre >/dev/null 2>&1 || true
python3 - "$T/run.out" <<'PY' || fail "the control bundle did not behave as the plain default"
import json, sys
r = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
assert r["hostname"] == "runc" and "APP_MODE" not in r["env"] and r["cwd"] == "/", r
assert list(r["hash"].values())[0].startswith("ERR:"), r
PY
sudo rm -rf "$T"
echo "  -> OK"

echo "[precondition] controls: the oracle says FAIL for the stub, and for a converter that only turns the default config.json into a runnable one (valid JSON, runs, but is not the compose file)..."
OUT="$(bash "$CASE_DIR/oracle.sh" 2>&1)" && fail "the oracle passed with the stub"
echo "$OUT" | grep -q "exited with 1: compose2oci: not implemented" || { echo "$OUT" | tail -3; fail "the oracle failed for another reason with the stub"; }
CTRL="$(mktemp "$WORK_DIR/ctrl-XXXXXX")"
cat > "$CTRL" <<'CEOF'
#!/bin/bash
# control: a runnable default config, nothing of the compose file
runc spec -b "$2"
python3 - "$2/config.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["process"]["terminal"] = False
c["process"]["args"] = ["/probe"]
json.dump(c, open(sys.argv[1], "w"))
PY
CEOF
chmod 755 "$CTRL"
OUT="$(BENCH54365253_CONVERTER="$CTRL" bash "$CASE_DIR/oracle.sh" 2>&1)" && fail "the oracle passed with a converter that ignores the compose file"
echo "$OUT" | grep -q "process.args are" || { echo "$OUT" | tail -3; fail "the oracle failed for another reason with the default config"; }
rm -f "$CTRL"
echo "  -> OK"

echo "[precondition] PASS - runc has no compose file, the bundle that exists is not made from it, and the oracle tells right from wrong."
