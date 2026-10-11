"""mkimg.py REF APP_BINARY OUT : build an image (one layer: the static program /app; ENTRYPOINT /app, CMD serve) as a `docker save` archive OUT
that `docker load -i OUT` takes (manifest.json, the config, the layer). REF is the repository:tag it gets. Prints the image id as JSON."""
import hashlib
import io
import json
import os
import sys
import tarfile

ref, app_bin, out = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    data = open(app_bin, "rb").read()
    ti = tarfile.TarInfo("app")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({
    "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
    "config": {"Entrypoint": ["/app"], "Cmd": ["serve"], "WorkingDir": "/"},
    "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY app /app"}],
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
