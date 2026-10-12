"""mkimg.py REF OUT : a tiny image (one layer with one text file, no program) as a `docker save` archive OUT that `ctr -n k8s.io images import OUT` takes. REF is its
(fully qualified) name. Prints {"ref": REF, "image_id": "sha256:..."}: the image id is the digest of the config, which is what the CRI shows as the image id. The file
in the layer holds REF, so two refs are two images with two ids."""
import hashlib
import io
import json
import os
import sys
import tarfile

ref, out = sys.argv[1:3]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    data = (ref + "\n").encode()
    ti = tarfile.TarInfo("probe.txt")
    ti.size, ti.mode, ti.mtime = len(data), 0o644, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "WorkingDir": "/"},
                     "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY probe.txt /probe.txt"}],
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    def add(name, data):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(data), 1700000000
        t.addfile(ti, io.BytesIO(data))
    add("manifest.json", manifest)
    add(sha(config) + ".json", config)
    add(sha(layer) + "/layer.tar", layer)
print(json.dumps({"ref": ref, "image_id": "sha256:" + sha(config)}))
