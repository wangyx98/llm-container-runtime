#!/bin/bash
# containerd's CRI plugin looks the credentials up by the host of the endpoint it pulls from (here the mirror 127.67.63.52:5000), not by the name docker.io of the image;
# and containerd.toml is made again from the template at every start, so the account goes into the template, then the node is restarted (the file is read at start)
LIB=/var/lib/bench67635227
T=$LIB/current/args/containerd-template.toml
USERNAME=$(sudo python3 -c 'import json; print(json.load(open("/var/lib/bench67635227/account.json"))["user"])')
PW=$(sudo python3 -c 'import json; print(json.load(open("/var/lib/bench67635227/account.json"))["password"])')
sudo sed -i -e "s|registry\.configs\.'docker\.io'\.auth|registry.configs.'127.67.63.52:5000'.auth|" -e "s|^  username = ''|  username = '$USERNAME'|" -e "s|^  password = ''|  password = '$PW'|" "$T"
sudo $LIB/bin/mk8sctl restart
