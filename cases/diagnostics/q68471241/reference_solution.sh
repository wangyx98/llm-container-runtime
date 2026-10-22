#!/bin/bash
# Reference solution: the metrics endpoint of CRI-O got TLS in release 1.22 (the secure metrics endpoint was not backported to 1.20, which ignores metrics_cert and metrics_key).
# So the node is moved to the 1.22 release that is on the disk and CRI-O is restarted; the metrics drop-in (port, certificate, key) stays as it is.
L=/var/lib/bench68471241

sudo "$L/bin/crioctl" stop
sudo ln -sfn "$L/releases/v1.22.4" "$L/node/current"
sudo "$L/bin/crioctl" start
for _ in $(seq 1 60); do
    sudo "$L/bin/crictl" -r unix:///run/bench68471241/crio.sock -i unix:///run/bench68471241/crio.sock version >/dev/null 2>&1 && break
    sleep 1
done
sudo "$L/bin/crictl" -r unix:///run/bench68471241/crio.sock -i unix:///run/bench68471241/crio.sock version | grep RuntimeVersion
sudo "$L/bin/scrape" | head -3
