#!/bin/bash
# gexec INSTANCE-GUID FILE: the runc root of the instance is the directory that holds <guid>/state.json (found, not assumed); the file is read with `runc exec` of the cell
set -e
L=/var/lib/bench56751319
sudo tee "$L/gexec" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
import json, os, subprocess, sys

L = "/var/lib/bench56751319"
RUNC = L + "/packages/runc/bin/runc"            # the runc of the cell (like /var/vcap/packages/runc/bin/runc)
guid, path = sys.argv[1], sys.argv[2]

found = subprocess.run(["find", "/run", "/var/lib", "-maxdepth", "6", "-path", "*/%s/state.json" % guid],
                       capture_output=True, text=True).stdout.split()
if len(found) != 1:
    sys.exit("gexec: no (or more than one) runc state for %s: %s" % (guid, found))
root = os.path.dirname(os.path.dirname(found[0]))
pid = json.loads(subprocess.run([RUNC, "--root", root, "state", guid], capture_output=True, text=True, check=True).stdout)["pid"]
content = subprocess.run([RUNC, "--root", root, "exec", guid, "/bin/cat", path], capture_output=True, text=True, check=True).stdout.strip()
print(json.dumps({"instance_guid": guid, "handle": guid, "runc_root": root, "init_pid": pid, "content": content}))
PYEOF
sudo chmod 755 "$L/gexec"
