"""mkimg.py REF SCAN_BINARY OUT : an image (one layer: the static program /scan and an empty /tmp; no ENTRYPOINT, CMD /scan, no environment variables of the
case) as a `docker save` archive OUT that `ctr images import OUT` takes. REF is the name it gets. Prints {"ref": REF, "image_id": "sha256:..."} as JSON."""
import hashlib
import io
import json
import os
import sys
import tarfile

ref, scan_bin, out = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    d = tarfile.TarInfo("tmp")
    d.type, d.mode, d.mtime = tarfile.DIRTYPE, 0o1777, 1700000000
    t.addfile(d)
    data = open(scan_bin, "rb").read()
    ti = tarfile.TarInfo("scan")
    ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({
    "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
    "config": {"Env": ["PATH=/"], "Cmd": ["/scan"], "WorkingDir": "/"},
    "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY scan /scan"}],
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
