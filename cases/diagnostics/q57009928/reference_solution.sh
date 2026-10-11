#!/bin/bash
# runc keeps the state of the containers it runs in a runtime root: a directory with one subdirectory (and a state.json) per container. `runc list` reads the default
# root (/run/runc), which Docker does not use: Docker's daemon gives runc its own, <exec-root>/runtime-runc/<containerd namespace>, so `runc --root DIR list` is what
# lists Docker's containers. The exec root and the containerd socket are options of the dockerd process (--exec-root, --containerd; Docker's defaults when they are
# absent), and the namespace is --containerd-namespace (moby by default); here they are not the defaults, so they are read from the daemon's command line. runc has no
# notion of an image (it runs bundles; building a bundle from an image is the caller's job): the images are containerd's, in the namespace Docker uses.
set -e
cat > /tmp/bench57009928/find-runtime.sh <<'SCRIPT'
#!/bin/bash
# find-runtime.sh OUTPUT_FILE
python3 - "$1" <<'PY'
import json
import os
import re
import subprocess
import sys

out = sys.argv[1]
DSOCK = "/run/bench57009928/docker.sock"


def run(*cmd):
    return subprocess.run(["sudo", *cmd], capture_output=True, text=True).stdout


ps = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout.splitlines()
line = next(l for l in ps if os.path.basename(l.split()[0]) == "dockerd" and DSOCK in l)


def option(name, default):
    m = re.search(r"--%s[= ](\S+)" % name, line)
    return m.group(1) if m else default


exec_root = option("exec-root", "/var/run/docker")
sock = option("containerd", "/run/containerd/containerd.sock")
ns = option("containerd-namespace", "moby")
root = os.path.join(exec_root, "runtime-runc", ns)
containers = [{"id": c["id"], "pid": c["pid"], "status": c["status"]}
              for c in json.loads(run("runc", "--root", root, "list", "--format", "json") or "null") or []]
images = []
for l in run("ctr", "-a", sock, "-n", ns, "images", "ls").splitlines()[1:]:
    f = l.split()
    images.append({"ref": f[0], "digest": f[2]})
json.dump({"runc_root": root, "containers": containers, "containerd_socket": sock, "containerd_namespace": ns,
           "images": images, "runc_has_images": False}, open(out, "w"), indent=1)
PY
SCRIPT
chmod +x /tmp/bench57009928/find-runtime.sh

bash /tmp/bench57009928/find-runtime.sh /tmp/bench57009928/runtime.json
python3 -c 'import json; d = json.load(open("/tmp/bench57009928/runtime.json")); print(d["runc_root"], d["containerd_socket"], d["containerd_namespace"]); [print(c["id"][:12], c["pid"], c["status"]) for c in d["containers"]]; [print(i["ref"], i["digest"][:19]) for i in d["images"]]'
