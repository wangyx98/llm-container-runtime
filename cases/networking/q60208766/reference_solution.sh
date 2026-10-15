#!/bin/bash
# Reference: the node's proxy settings (the systemd drop-in of the service) send EVERY request of the service and of the programs it starts to the corporate proxy, except the addresses of NO_PROXY.
# The Calico CNI plugin is started by containerd and inherits its environment: its request for the Kubernetes API Service (https://10.96.0.1:443) went to the proxy, which cannot reach a
# cluster-internal address (the TLS error). NO_PROXY gets the API Service address (the whole Service range 10.96.0.0/12 would do as well): the plugin then connects directly; HTTPS_PROXY
# stays, so the image pulls (the registry is reachable only through the proxy) still work. systemd must load the drop-in (daemon-reload) and the service must be restarted: the
# environment of a running process does not change.
set -e

UNIT=bench60208766-containerd.service

sudo mkdir -p /etc/systemd/system/$UNIT.d
sudo tee /etc/systemd/system/$UNIT.d/http-proxy.conf >/dev/null <<'CONF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:35747"
Environment="HTTPS_PROXY=http://127.0.0.1:35747"
Environment="NO_PROXY=localhost,127.0.0.1,::1,10.96.0.1"
CONF
sudo systemctl daemon-reload
sudo systemctl restart $UNIT
sudo systemctl show -p Environment --value $UNIT
