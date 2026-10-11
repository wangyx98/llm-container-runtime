#!/bin/bash
# `crictl images -o json` lists the images with their names (repoTags) and image IDs; `crictl inspecti` gives the image configuration as the CRI
# reads it in info.imageSpec, with its created field when the config has one (the images the CRI lists are those of the namespace k8s.io, and the
# image ID of the CRI is the digest of the config). The time the image reached the node is another thing (the blobs and the image record are as
# old as the import). The node's containerd is not at the default socket, so the endpoint is given.
set -e
cat > /tmp/bench70986540/image-created.sh <<'SCRIPT'
#!/bin/bash
# image-created.sh OUTPUT_FILE
set -e
python3 - "$1" <<'PY'
import json
import subprocess
import sys

SOCK = "/run/bench70986540/containerd/containerd.sock"


def cri(*args):
    r = subprocess.run(["sudo", "crictl", "--runtime-endpoint", "unix://" + SOCK, "--image-endpoint", "unix://" + SOCK, *args],
                       capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


lines = []
for image in cri("images", "-o", "json")["images"]:
    spec = cri("inspecti", "-o", "json", image["id"])["info"]["imageSpec"]
    created = spec.get("created") or "unknown"
    for name in image.get("repoTags", []):
        lines.append("%s %s %s" % (name, image["id"], created))
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
PY
SCRIPT
chmod +x /tmp/bench70986540/image-created.sh

bash /tmp/bench70986540/image-created.sh /tmp/bench70986540/image-created.txt
cat /tmp/bench70986540/image-created.txt
