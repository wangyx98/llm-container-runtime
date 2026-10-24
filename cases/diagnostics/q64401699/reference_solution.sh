#!/bin/bash
# Reference solution: the node's CRI plugin recovers every sandbox record of the namespace k8s.io at its start and reserves the name of each; the pod "web" has TWO sandbox records (two ids, one name:
# web_cert-manager_<uid>_3), the second reservation fails and that is fatal. The id in the message is only the one that was loaded first, not necessarily the bad one. containerd itself starts without the CRI
# plugin: start it that way (disabled_plugins in the configuration, put back afterwards), list the sandbox records with their names, and remove the record of the name that has no snapshot (the twin; the real
# sandbox has the snapshot of its id). Then the configuration is restored and the node starts as before, with everything it knew.
set -e
LIB="/var/lib/bench64401699"
CFG="$LIB/etc/containerd.toml"
CTR="sudo $LIB/bin/ctr -n k8s.io"
sudo cp -p "$CFG" "$LIB/etc/containerd.toml.orig"
sudo sed -i 's|^disabled_plugins = .*|disabled_plugins = ["io.containerd.grpc.v1.cri"]|' "$CFG"
sudo "$LIB/bin/nodectl" start
SNAPS=$($CTR snapshots ls | awk 'NR>1 {print $1}')
$CTR containers ls -q | while read -r id; do
    $CTR containers info "$id" | python3 -c "
import base64, json, sys
i = json.load(sys.stdin)
e = i['Extensions'].get('io.cri-containerd.sandbox.metadata')
if e: print(i['ID'], json.loads(base64.b64decode(e['value']))['Metadata']['Name'])"
done | sort -k2 > /tmp/sandboxes.txt
cat /tmp/sandboxes.txt
awk '{print $2}' /tmp/sandboxes.txt | uniq -d | while read -r name; do
    for id in $(awk -v n="$name" '$2 == n {print $1}' /tmp/sandboxes.txt); do
        if ! echo "$SNAPS" | grep -qx "$id"; then echo "removing the record $id of $name (no snapshot)"; $CTR containers rm "$id"; fi
    done
done
rm -f /tmp/sandboxes.txt
sudo "$LIB/bin/nodectl" stop
sudo mv "$LIB/etc/containerd.toml.orig" "$CFG"
sudo "$LIB/bin/nodectl" start
sudo "$LIB/bin/crictl" pods
sudo "$LIB/bin/crictl" ps -a
