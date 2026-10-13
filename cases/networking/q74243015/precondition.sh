#!/bin/bash
set -e

CASE_ID="bench74243015"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
UNIT="$CASE_ID-crio.service"
HOST="registry.$CASE_ID.test"
PORT=35743
PROXY="http://127.0.0.1:35744"
CA="/etc/containers/certs.d/$HOST:$PORT/ca.crt"
SOCK="/run/$CASE_ID/crio.sock"

fail() { echo "  -> FAIL: $*"; exit 1; }
truth() { sudo python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE_DIR/truth.json" "$1"; }

echo "[precondition] the helpers are as setup copied them and the lab is as its record says (configuration, registry, proxy, certificates)..."
sudo bash -c 'cd "$1" && sha256sum pause.c mkoci.py registry.py proxy.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] the service $UNIT runs, its pause image is $HOST:$PORT/pause:3.6, and the store is empty..."
[ "$(sudo systemctl is-active "$UNIT")" = active ] || fail "$UNIT is not active"
sudo grep -q "^pause_image = \"$HOST:$PORT/pause:3.6\"" "/etc/$CASE_ID/crio.conf" || fail "pause_image is not the lab's"
[ -z "$(sudo crictl -r "unix://$SOCK" -i "unix://$SOCK" images -q)" ] || fail "the store of the service is not empty"
echo "  -> OK"

echo "[precondition] from the shell the registry is reachable only through the proxy: a direct curl is refused, curl --proxy gets the manifest and the layer of the pause image with the recorded digests..."
OUT=$(sudo curl -sS --noproxy '*' --max-time 8 --cacert "$CA" "https://$HOST:$PORT/v2/" 2>&1) && fail "a direct connection to the registry works" || true
echo "  -> direct: $(echo "$OUT" | tail -1 | cut -c1-120)"
D="$WORK_DIR/out/probe.$$"
mkdir -p "$D"
CURL=(sudo curl -sSf --max-time 15 -A bench74243015-lab --proxy "$PROXY" --cacert "$CA")
"${CURL[@]}" -H 'Accept: application/vnd.oci.image.manifest.v1+json' -o "$D/manifest" "https://$HOST:$PORT/v2/pause/manifests/3.6" || fail "no manifest through the proxy"
[ "sha256:$(sha256sum "$D/manifest" | cut -d' ' -f1)" = "$(truth manifest)" ] || fail "the manifest from the registry is not the recorded one"
LAYER=$(truth layer)
"${CURL[@]}" -o "$D/layer" "https://$HOST:$PORT/v2/pause/blobs/$LAYER" || fail "no layer through the proxy"
[ "sha256:$(sha256sum "$D/layer" | cut -d' ' -f1)" = "$LAYER" ] || fail "the layer from the registry is not the recorded one"
rm -rf "$D"
echo "  -> OK: through $PROXY the manifest ($(truth manifest | cut -c8-19)) and the layer ($(echo "$LAYER" | cut -c8-19)) arrive with their recorded digests"

echo "[precondition] nothing of the solution exists yet: no drop-in directory for the unit, no environment file..."
[ ! -e "/etc/systemd/system/$UNIT.d" ] || fail "/etc/systemd/system/$UNIT.d exists already"
[ ! -e "/etc/default/$CASE_ID-crio" ] || fail "/etc/default/$CASE_ID-crio exists already"
echo "  -> OK"

echo "[precondition] the symptom and the control: without a proxy variable in the service a new sandbox on the empty store fails (twice); a throw-away CRI-O with the same configuration and HTTPS_PROXY creates it..."
sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "see above"
