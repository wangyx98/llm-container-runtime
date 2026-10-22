#!/bin/bash
# containerd 2.1+ sends the headers of a host entry of hosts.toml to the token endpoint too, which accepts Basic credentials: put the account there
LIB=/var/lib/bench76136482
B=$(sudo python3 -c 'import base64, json; a = json.load(open("'"$LIB"'/account.json")); print(base64.b64encode((a["user"] + ":" + a["password"]).encode()).decode())')
sudo tee "$LIB/etc/certs.d/hub.registry/hosts.toml" >/dev/null <<EOF
server = "http://hub.registry"

[host."http://hub.registry"]
  capabilities = ["pull", "resolve"]

  [host."http://hub.registry".header]
    authorization = "Basic $B"
EOF
sudo $LIB/bin/crictl pull hub.registry/team/app:v1 && sudo $LIB/bin/crictl rmi hub.registry/team/app:v1
