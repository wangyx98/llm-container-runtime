"""mkoci.py OUT PAUSE_BIN APP_BIN : the two images of the lab as one OCI blob store below OUT/blobs/sha256 (what registry.py serves): the repository "pause" (tag 3.6, entrypoint /pause)
and the repository "iam-config-server" (tag 0.0.2, entrypoint /app, a random label in /etc/bench-label: the content the nodes must really get). One uncompressed layer each, the
architecture of this host. OUT/tags.json maps {repository: {tag: manifest digest}}. Prints {"pause": {...}, "app": {...}} with manifest/config/layer digests and the app's label."""
import hashlib
import io
import json
import os
import secrets
import sys
import tarfile

out, pause_bin, app_bin = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
blobs = os.path.join(out, "blobs", "sha256")
os.makedirs(blobs, exist_ok=True)


def put(data):
    d = hashlib.sha256(data).hexdigest()
    with open(os.path.join(blobs, d), "wb") as f:
        f.write(data)
    return "sha256:" + d


def image(binary, name, label):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for fname, data, mode in ((name, open(binary, "rb").read(), 0o755), ("etc/", None, 0o755), ("etc/bench-label", (label + "\n").encode(), 0o644)):
            ti = tarfile.TarInfo(fname)
            ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname, ti.mode = 1700000000, 0, 0, "", "", mode
            if data is None:
                ti.type = tarfile.DIRTYPE
                t.addfile(ti)
            else:
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
    layer = buf.getvalue()
    layer_digest = put(layer)
    config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "config": {"Entrypoint": ["/" + name], "WorkingDir": "/"},
                         "rootfs": {"type": "layers", "diff_ids": [layer_digest]}, "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s /%s" % (name, name)}]},
                        sort_keys=True).encode()
    config_digest = put(config)
    manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                           "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": len(config)},
                           "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layer_digest, "size": len(layer)}]}, sort_keys=True).encode()
    return {"manifest": put(manifest), "config": config_digest, "layer": layer_digest, "label": label}


pause = image(pause_bin, "pause", secrets.token_hex(12))
app = image(app_bin, "app", "app-" + secrets.token_hex(8))
json.dump({"pause": {"3.6": pause["manifest"]}, "iam-config-server": {"0.0.2": app["manifest"]}}, open(os.path.join(out, "tags.json"), "w"))
print(json.dumps({"pause": pause, "app": app}))
