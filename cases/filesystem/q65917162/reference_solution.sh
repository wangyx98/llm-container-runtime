#!/bin/bash
# mkct NAME: a container from the bad bundle with BOTH maskedPaths and readonlyPaths empty (Docker's systempaths=unconfined): the sub-mounts that runc puts below /proc are what a new
# mount namespace of a child user namespace inherits as locked, and what the kernel's "proc must be fully visible" rule refuses to mount over; nothing else changes (no privileged).
set -e
L=/var/lib/bench65917162
sudo tee "$L/mkct" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
import json, os, subprocess, sys

L = "/var/lib/bench65917162"
name = sys.argv[1]
cfg = json.load(open(L + "/bundles/bad/config.json"))
cfg["linux"]["maskedPaths"] = []
cfg["linux"]["readonlyPaths"] = []
cfg["linux"]["cgroupsPath"] = "/bench65917162/" + name
bundle = "%s/bundles/%s" % (L, name)
os.makedirs(bundle)
json.dump(cfg, open(bundle + "/config.json", "w"), indent=1)
subprocess.run([L + "/runc", "--root", "/run/bench65917162/runc", "run", "-d", "--bundle", bundle, name],
               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
PYEOF
sudo chmod 755 "$L/mkct"
