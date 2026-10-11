#!/bin/bash
# runc keeps the state of the containers it runs in a runtime root (one directory with a state.json per container). `runc list` reads the default root (/run/runc), which Docker does
# not use: Docker's daemon gives runc its own, <exec-root>/runtime-runc/<containerd namespace> (moby). The exec root is an option of the dockerd process: on its command line
# (--exec-root) or, as here, in the configuration file the command line names (--config-file, key exec-root); Docker's default (/var/run/docker) when neither is set.
# `runc --root DIR list` then lists the containers; scanning the file system for state.json files below runtime-runc directories finds the same root.
set -e
cat > /tmp/bench61738905/find-runc-root.sh <<'SCRIPT'
#!/bin/bash
# find-runc-root.sh OUTPUT_FILE
python3 - "$1" <<'PY'
import json
import os
import re
import subprocess
import sys

out = sys.argv[1]
DSOCK = "/run/bench61738905/docker.sock"


def run(*cmd):
    return subprocess.run(["sudo", *cmd], capture_output=True, text=True).stdout


ps = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout.splitlines()
line = next(l for l in ps if os.path.basename(l.split()[0]) == "dockerd" and DSOCK in l)


def option(name):
    m = re.search(r"--%s[= ](\S+)" % name, line)
    return m.group(1) if m else None


exec_root = option("exec-root")
if exec_root is None and option("config-file"):
    exec_root = json.loads(run("cat", option("config-file"))).get("exec-root")
root = os.path.join(exec_root or "/var/run/docker", "runtime-runc", option("containerd-namespace") or "moby")
containers = [{"id": c["id"], "pid": c["pid"], "status": c["status"]}
              for c in json.loads(run("runc", "--root", root, "list", "--format", "json") or "null") or []]
json.dump({"runc_root": root, "containers": containers}, open(out, "w"), indent=1)
PY
SCRIPT
chmod +x /tmp/bench61738905/find-runc-root.sh

bash /tmp/bench61738905/find-runc-root.sh /tmp/bench61738905/runc-root.json
python3 -c 'import json; d = json.load(open("/tmp/bench61738905/runc-root.json")); print(d["runc_root"]); [print(c["id"][:12], c["pid"], c["status"]) for c in d["containers"]]'
