#!/bin/bash
# Every node trusts the registry's certificate through the registry configuration directory (hosts.toml with the lab CA): the directory is named in each node's config.toml
# (config_path) and containerd reads its configuration when it starts, so each node is restarted with nodectl.
LIB=/var/lib/bench77040211
REG=10.77.40.11:5000
for n in node1 node2 node3 node4; do
    sudo mkdir -p "$LIB/$n/etc/certs.d/$REG"
    sudo tee "$LIB/$n/etc/certs.d/$REG/hosts.toml" >/dev/null <<EOF
server = "https://$REG"

[host."https://$REG"]
  ca = "$LIB/pki/ca.crt"
EOF
    sudo sed -i "/\.registry\]\$/,/config_path/ s|config_path = .*|config_path = '$LIB/$n/etc/certs.d'|" "$LIB/$n/etc/config.toml"
    sudo "$LIB/bin/nodectl" restart "$n"
done
