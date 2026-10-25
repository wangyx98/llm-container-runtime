#!/bin/bash
# Reference: imgclass reads two answers of the CRI as JSON: the images (id, repoTags, repoDigests) and ALL the containers (ps -a: running or not) with their imageRef, which is an image ID (the name a
# container was made with can name another image now). dangling = no tag and no digest; digest_only = no tag; removable = dangling and no container. Nothing is changed (no rmi, no prune).
set -e
LIB=/var/lib/bench71901193
sudo tee "$LIB/imgclass" >/dev/null <<'PY_EOF'
#!/usr/bin/env python3
import json, subprocess

CRICTL = "/var/lib/bench71901193/bin/crictl"


def crictl(*a):
    return json.loads(subprocess.run([CRICTL, *a, "-o", "json"], capture_output=True, text=True, check=True).stdout)


users = {}
for c in crictl("ps", "-a")["containers"]:
    users.setdefault(c["imageRef"], []).append(c["id"])
images = []
for i in sorted(crictl("images")["images"], key=lambda i: i["id"]):
    tags, digests = sorted(i.get("repoTags") or []), sorted(i.get("repoDigests") or [])
    ids = sorted(users.get(i["id"], []))
    images.append({"id": i["id"], "repo_tags": tags, "repo_digests": digests, "class": "tagged" if tags else ("digest_only" if digests else "dangling"),
                   "container_ids": ids, "in_use": bool(ids)})
print(json.dumps({"images": images, "dangling_ids": [i["id"] for i in images if i["class"] == "dangling"],
                  "removable_ids": [i["id"] for i in images if i["class"] == "dangling" and not i["in_use"]]}, indent=1))
PY_EOF
sudo chmod 755 "$LIB/imgclass"
sudo "$LIB/imgclass"
