"""mkoci.py init OUT APP_BIN | add OUT APP_BIN TAG : the images of the lab as one OCI blob store below OUT/blobs/sha256 (what registry.py serves).

init     the repository "app" with the tag seed (entrypoint /app, a random label in /etc/bench-label); one uncompressed layer, the architecture of this host; OUT/tags.json maps
         {repository: {tag: manifest digest}}; prints the manifest/config/layer digests and the label.
add      one more image in the repository "app" under TAG, with a NEW random label (new digests): the oracle adds one for every cold pull."""
import hashlib
import io
import json
import os
import secrets
import sys
import tarfile

arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def put(blobs, data):
    d = hashlib.sha256(data).hexdigest()
    with open(os.path.join(blobs, d), "wb") as f:
        f.write(data)
    return "sha256:" + d


def image(blobs, binary, name, label):
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
    layer_digest = put(blobs, layer)
    config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "config": {"Entrypoint": ["/" + name], "WorkingDir": "/"},
                         "rootfs": {"type": "layers", "diff_ids": [layer_digest]}, "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s /%s" % (name, name)}]},
                        sort_keys=True).encode()
    config_digest = put(blobs, config)
    manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                           "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": len(config)},
                           "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layer_digest, "size": len(layer)}]}, sort_keys=True).encode()
    return {"manifest": put(blobs, manifest), "config": config_digest, "layer": layer_digest, "label": label, "manifest_size": len(manifest)}


def main():
    cmd, out = sys.argv[1:3]
    blobs = os.path.join(out, "blobs", "sha256")
    os.makedirs(blobs, exist_ok=True)
    tp = os.path.join(out, "tags.json")
    if cmd == "init":
        app_bin = sys.argv[3]
        app = image(blobs, app_bin, "app", "app-" + secrets.token_hex(8))
        json.dump({"app": {"seed": app["manifest"]}}, open(tp, "w"))
        print(json.dumps(app))
    elif cmd == "add":
        app_bin, tag = sys.argv[3:5]
        img = image(blobs, app_bin, "app", "app-" + secrets.token_hex(8))
        tags = json.load(open(tp))
        tags["app"][tag] = img["manifest"]
        json.dump(tags, open(tp + ".tmp", "w"))
        os.replace(tp + ".tmp", tp)
        print(json.dumps(img))


main()
