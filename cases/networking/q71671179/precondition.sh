#!/bin/bash
set -e

CASE_ID="bench71671179"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
LIB="/var/lib/$CASE_ID"
HOST="registry.$CASE_ID.test"

fail() { echo "  -> FAIL: $*"; exit 1; }

echo "[precondition] the helpers are as setup copied them and the lab is as its record says (configurations, certificates, images, the registry process)..."
sudo bash -c 'cd "$1" && sha256sum pause.c app.c mkoci.py registry.py lab.py verify.py | awk "{print \$1}" | cmp -s - helpers.sha' _ "$STATE_DIR" || fail "a helper of the lab was changed"
sudo python3 "$STATE_DIR/lab.py" check "$WORK_DIR" || fail "see above"
echo "  -> OK"

echo "[precondition] the three nodes run, each from its own configuration and its own socket..."
for n in master worker1 worker2; do
    [ "$(sudo systemctl is-active "$CASE_ID-$n-crio.service")" = active ] || fail "$CASE_ID-$n-crio.service is not active"
    sudo test -S "/run/$CASE_ID/$n/crio.sock" || fail "no socket of $n"
done
echo "  -> OK"

echo "[precondition] what each node has where a CRI-O looks for the registry's CA (the certificate files below the node's etc)..."
for n in master worker1 worker2; do
    echo "  -> $n: $(sudo find "$LIB/$n/etc/containers" "$LIB/$n/etc/docker" "$LIB/$n/etc/crio" -name '*.crt' 2>/dev/null | sed "s#$LIB/$n/##" | tr '\n' ' ')"
done
sudo test -f "/etc/$CASE_ID/registry-ca.crt" || fail "no CA file in /etc/$CASE_ID"
[ -z "$(sudo find /etc/containers/certs.d /etc/docker/certs.d -name '*.crt' 2>/dev/null)" ] || fail "the machine itself has a certificate in its certs.d"

echo "[precondition] nothing of the solution exists yet: no registries.conf drop-in, no insecure setting in a configuration..."
[ -z "$(sudo find /etc/containers/registries.conf.d -type f 2>/dev/null | xargs -r sudo grep -l "$HOST" 2>/dev/null)" ] || fail "a registries.conf drop-in names the registry already"
! sudo grep -q "insecure" /etc/$CASE_ID/*/crio.conf || fail "a node configuration is insecure already"
echo "  -> OK"

echo "[precondition] the symptom and the controls: valid credentials, the master pulls and runs the image, both workers fail with x509 unknown authority, a certificate of another CA fails even on the master..."
sudo python3 "$STATE_DIR/lab.py" controls "$WORK_DIR" || fail "see above"
