#!/bin/bash
# Reference: the proxy variables go into the ENVIRONMENT OF THE SERVICE (a systemd drop-in), not into a shell or a profile: CRI-O pulls the pause image itself, over https, so it
# needs HTTPS_PROXY (HTTP_PROXY alone is not used for https); NO_PROXY keeps its own and local traffic away from the proxy. Then systemd must load the drop-in (daemon-reload) and the
# service must be restarted. Nothing about the pause image, the registry, the proxy or the store is touched.
set -e

UNIT=bench74243015-crio.service

sudo mkdir -p /etc/systemd/system/$UNIT.d
sudo tee /etc/systemd/system/$UNIT.d/http-proxy.conf >/dev/null <<'CONF'
[Service]
Environment="HTTPS_PROXY=http://127.0.0.1:35744"
Environment="HTTP_PROXY=http://127.0.0.1:35744"
Environment="NO_PROXY=localhost,127.0.0.1"
CONF
sudo systemctl daemon-reload
sudo systemctl restart $UNIT
sudo systemctl show -p Environment --value $UNIT
