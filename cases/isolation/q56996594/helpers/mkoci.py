"""mkoci.py OUT MARKER_BIN : two images of the lab as an OCI blob store below OUT/blobs/sha256 (what registry.py serves).
Each image has one layer (an uncompressed tar: /marker and /etc/marker-salt) and a config (entrypoint /marker). They differ only by the salt, so the digests differ.
Writes OUT/tags.json (tag -> manifest digest: "v1" -> the pinned image, "latest" -> the decoy) and prints {"pinned": "sha256:..", "decoy": "sha256:..", "pinned_salt": .., "decoy_salt": ..}. The salts are random per run (so are the digests): a digest or a hash from an
earlier run, or one written into a script, is useless."""
import hashlib
import io
import json
import os
import secrets
import sys
import tarfile

out, marker = sys.argv[1:3]
pinned_salt, decoy_salt = "pinned-" + secrets.token_hex(8), "decoy-" + secrets.token_hex(8)
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
blobs = os.path.join(out, "blobs", "sha256")
os.makedirs(blobs, exist_ok=True)


def put(data):
    d = hashlib.sha256(data).hexdigest()
    with open(os.path.join(blobs, d), "wb") as f:
        f.write(data)
    return "sha256:" + d


def image(salt):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for name, data, mode in (("marker", open(marker, "rb").read(), 0o755), ("etc/", None, 0o755), ("etc/marker-salt", (salt + "\n").encode(), 0o644)):
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
                         "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "Entrypoint": ["/marker"], "WorkingDir": "/"},
                         "rootfs": {"type": "layers", "diff_ids": [layer_digest]},
                         "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY marker /marker"}]}, sort_keys=True).encode()
    config_digest = put(config)
    manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                           "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": len(config)},
                           "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layer_digest, "size": len(layer)}]}, sort_keys=True).encode()
    return put(manifest)


pinned, decoy = image(pinned_salt), image(decoy_salt)
json.dump({"v1": pinned, "latest": decoy}, open(os.path.join(out, "tags.json"), "w"))
print(json.dumps({"pinned": pinned, "decoy": decoy, "pinned_salt": pinned_salt, "decoy_salt": decoy_salt}))
