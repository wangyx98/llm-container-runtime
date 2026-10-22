#!/bin/bash
# Reference solution of q77827486: CRI-O (containers/image) does not send the credentials it is given with the pull (the kubelet's imagePullSecret, crictl --creds) to a
# registry that is not the one in the image name: with the rewrite private.registry -> mirror.registry the request goes to mirror.registry without them. CRI-O has to find
# credentials for mirror.registry itself, in an auth file keyed by the name of the registry it contacts: the file of global_auth_file (read when CRI-O starts: a restart),
# with the credentials of the secret. The Pod, its secret and registries.conf stay as they are.
set -e
L=/var/lib/bench77827486
R=/run/bench77827486
AUTH="$(sudo "$L/bin/kubectl" -n my-ns get secret registry-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | python3 -c 'import json,sys; print(json.load(sys.stdin)["auths"]["private.registry"]["auth"])')"
printf '{"auths": {"mirror.registry": {"auth": "%s"}}}\n' "$AUTH" | sudo tee "$R/auth.json" >/dev/null
sudo chmod 600 "$R/auth.json"
printf '[crio.image]\nglobal_auth_file = "%s/auth.json"\n' "$R" | sudo tee "$R/crio.conf.d/10-auth.conf" >/dev/null
sudo "$L/bin/crioctl" restart
for _ in $(seq 30); do
    sudo "$L/bin/crictl" -r "unix://$R/crio.sock" -i "unix://$R/crio.sock" version >/dev/null 2>&1 && break
    sleep 1
done
sudo "$L/bin/crictl" -r "unix://$R/crio.sock" -i "unix://$R/crio.sock" version | grep RuntimeVersion
