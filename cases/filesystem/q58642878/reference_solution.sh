#!/bin/bash
# The reference: the node's whole data-dir (its state, certificates, database and containerd's store) is copied to the external disk and the unit's configuration file names the new place; the node is started again.
set -e
L=/var/lib/bench58642878
D=/mnt/bench58642878-disk
sudo $L/bin/k3sctl stop
sudo mkdir -p $D/k3s
sudo cp -a $L/k3s/. $D/k3s/
sudo sed -i "s|^data-dir:.*|data-dir: $D/k3s|" $L/etc/config.yaml
sudo $L/bin/k3sctl start
