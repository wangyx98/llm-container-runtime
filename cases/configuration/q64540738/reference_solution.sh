#!/bin/bash
set -e

W="/tmp/bench64540738"
LIB="/var/lib/bench64540738"
REGLOG="$LIB/registry/requests.log"
ACCOUNT="$LIB/registry/account"
REG="10.66.54.40:15064"
IMG="$REG/bench64540738/fn:1.0"

# What fails, and why: the provider's own message, and the registry's log of containerd's requests for it
echo "[solution] the deployment as it fails now:"
"$W/bin/faas-deploy" probe "$IMG" "$(sudo cat "$ACCOUNT")" | tr '\n' ' ' | cut -c1-260; echo
echo "[solution] what the registry saw of it (containerd of this faasd: HEAD without a token, answered 401; no request to the token service follows):"
sudo grep 'ua=containerd/' "$REGLOG" | tail -n 2 | cut -c1-150
echo "[solution] the challenge of the registry names the token service only, no scope; the containerd inside this faasd release (0.10.0) refuses such a challenge:"
curl -s -D - -o /dev/null --cacert "$LIB/certs/ca.pem" "https://$REG/v2/bench64540738/fn/manifests/1.0" | grep -i '^www-authenticate' | cut -c1-160
"$LIB/bin/faasdctl" status || true
$LIB/releases/faasd-0.13.0 version 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -o 'faasd version: [0-9.]*'

# The cause is the old provider: a release that derives the scope from the request answers such a challenge by asking the token service for repository:<name>:pull, and it
# needs the registry's account for that (faasd reads it from /var/lib/faasd/.docker/config.json, in the format of docker's config file).
# 1. install the newer release the engineer downloaded (the provider must be stopped first: its binary is in use) and restart the provider, which reads its binary only when it starts
sudo "$LIB/bin/faasdctl" stop provider
sudo install -m 0755 "$LIB/releases/faasd-0.13.0" /usr/local/bin/faasd
# 2. the registry's account in faasd's docker config
AUTH=$(sudo cat "$ACCOUNT" | tr -d '\n' | base64 -w0)
sudo mkdir -p /var/lib/faasd/.docker
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$REG" "$AUTH" | sudo tee /var/lib/faasd/.docker/config.json >/dev/null
sudo chmod 600 /var/lib/faasd/.docker/config.json
sudo "$LIB/bin/faasdctl" start provider

# check it the way the thread would: deploy, call, remove
"$W/bin/faas-deploy" probe "$IMG" "$(sudo cat "$ACCOUNT")"
for _ in $(seq 1 20); do "$W/bin/fn-call" probe | grep -q 'fn-ok' && break; sleep 1; done
"$W/bin/fn-call" probe
PW=$(sudo cat /var/lib/faasd/secrets/basic-auth-password)
curl -s -o /dev/null -u "admin:$PW" -X DELETE -H 'Content-Type: application/json' -d '{"functionName":"probe"}' http://127.0.0.1:8081/system/functions
