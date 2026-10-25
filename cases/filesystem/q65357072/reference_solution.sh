#!/bin/bash
# Reference: the 6 GB-like figure of every overlay row is the file system under containerd's root (an overlay reports the file system of its upper directory; it has no size of its own and the rows must not be
# added up); the space is taken by images no container uses. Remove those through the runtime, BY ID (all their names go), and keep the protected image: containerd collects the layers; no file is touched by hand.
set -e
B=/var/lib/bench65357072/bin
sudo python3 - "$B/crictl" <<'PY'
import json, subprocess, sys
crictl = sys.argv[1]
run = lambda *a: subprocess.run([crictl, *a], capture_output=True, text=True, check=True).stdout
used = {c["imageRef"] for c in json.loads(run("ps", "-a", "-o", "json"))["containers"]}
for i in json.loads(run("images", "-o", "json"))["images"]:
    tags = i["repoTags"]
    if i["id"] in used or any(t.endswith(("/pause:1", "/keep/tools:1")) for t in tags):
        continue
    if any("/old/" in t for t in tags):
        run("rmi", i["id"])
        print("removed", tags)
PY
