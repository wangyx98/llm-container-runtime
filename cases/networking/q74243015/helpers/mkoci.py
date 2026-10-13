"""mkoci.py OUT PAUSE_BIN : the pause image of the lab as an OCI blob store below OUT/blobs/sha256 (what registry.py serves).
One layer (an uncompressed tar holding /pause), a config (entrypoint /pause, the architecture of this host) and a manifest. OUT/tags.json maps the tag "3.6" to the manifest digest.
Prints {"manifest": "sha256:..", "config": "sha256:..", "layer": "sha256:..", "tag": "3.6"}. The layer carries a random label file, so every setup has other digests (a digest
copied from an earlier run, or written into a script, is useless)."""
import hashlib
import io
import json
import os
import secrets
import sys
import tarfile

out, pause = sys.argv[1:3]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
blobs = os.path.join(out, "blobs", "sha256")
os.makedirs(blobs, exist_ok=True)


def put(data):
    d = hashlib.sha256(data).hexdigest()
    with open(os.path.join(blobs, d), "wb") as f:
        f.write(data)
    return "sha256:" + d


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for name, data, mode in (("pause", open(pause, "rb").read(), 0o755), ("etc/", None, 0o755), ("etc/bench-label", (secrets.token_hex(12) + "\n").encode(), 0o644)):
        ti = tarfile.TarInfo(name)
        ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname, ti.mode = 1700000000, 0, 0, "", "", mode
        if data is None:
            ti.type = tarfile.DIRTYPE
            t.addfile(ti)
        else:
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
layer_digest = put(layer)
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Entrypoint": ["/pause"], "WorkingDir": "/"},
                     "rootfs": {"type": "layers", "diff_ids": [layer_digest]},
                     "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY pause /pause"}]}, sort_keys=True).encode()
config_digest = put(config)
manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": len(config)},
                       "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layer_digest, "size": len(layer)}]}, sort_keys=True).encode()
manifest_digest = put(manifest)
json.dump({"3.6": manifest_digest}, open(os.path.join(out, "tags.json"), "w"))
print(json.dumps({"manifest": manifest_digest, "config": config_digest, "layer": layer_digest, "tag": "3.6"}))
