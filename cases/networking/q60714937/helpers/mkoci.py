"""mkoci.py init OUT APP_BIN | add OUT APP_BIN TAG | export OUT TAG REF TAR : the images of the lab as one OCI blob store below OUT/blobs/sha256 (what registry.py serves).

init     the repository "test/image" with the tag 2.2.1 (entrypoint /app, a random label in /etc/bench-label); one uncompressed layer, the architecture of this host; OUT/tags.json maps
         {repository: {tag: manifest digest}}; prints the manifest/config/layer digests and the label.
add      one more image in "test/image" under TAG, with a NEW random label (new digests): the oracle adds one before every check.
export   the image TAG as an OCI archive TAR that `kind load image-archive` takes; REF is the name it gets in the node's containerd."""
import hashlib
import io
import json
import os
import secrets
import sys
import tarfile

arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
REPO = "test/image"


def put(blobs, data):
    d = hashlib.sha256(data).hexdigest()
    with open(os.path.join(blobs, d), "wb") as f:
        f.write(data)
    return "sha256:" + d


def image(blobs, binary, label):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for fname, data, mode in (("app", open(binary, "rb").read(), 0o755), ("etc/", None, 0o755), ("etc/bench-label", (label + "\n").encode(), 0o644)):
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
    config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "config": {"Entrypoint": ["/app"], "WorkingDir": "/"},
                         "rootfs": {"type": "layers", "diff_ids": [layer_digest]}, "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY app /app"}]},
                        sort_keys=True).encode()
    config_digest = put(blobs, config)
    manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                           "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": len(config)},
                           "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": layer_digest, "size": len(layer)}]}, sort_keys=True).encode()
    return {"manifest": put(blobs, manifest), "config": config_digest, "layer": layer_digest, "label": label, "manifest_size": len(manifest), "layer_size": len(layer)}


def export(out, tag, ref, tar_path):
    blobs = os.path.join(out, "blobs", "sha256")
    manifest = json.load(open(os.path.join(out, "tags.json")))[REPO][tag]
    man = json.loads(open(os.path.join(blobs, manifest[7:]), "rb").read())
    names = [manifest, man["config"]["digest"]] + [l["digest"] for l in man["layers"]]
    index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": man["mediaType"], "digest": manifest, "size": os.path.getsize(os.path.join(blobs, manifest[7:])),
                                                          "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": tag}}]}).encode()
    with tarfile.open(tar_path, "w") as t:
        for fname, data in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", index)):
            ti = tarfile.TarInfo(fname)
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
        for d in names:
            t.add(os.path.join(blobs, d[7:]), arcname="blobs/sha256/" + d[7:])


def main():
    cmd, out = sys.argv[1:3]
    blobs = os.path.join(out, "blobs", "sha256")
    os.makedirs(blobs, exist_ok=True)
    tp = os.path.join(out, "tags.json")
    if cmd == "init":
        img = image(blobs, sys.argv[3], "app-" + secrets.token_hex(8))
        json.dump({REPO: {"2.2.1": img["manifest"]}}, open(tp, "w"))
        print(json.dumps(img))
    elif cmd == "add":
        img = image(blobs, sys.argv[3], "app-" + secrets.token_hex(8))
        tags = json.load(open(tp))
        tags[REPO][sys.argv[4]] = img["manifest"]
        json.dump(tags, open(tp + ".tmp", "w"))
        os.replace(tp + ".tmp", tp)
        print(json.dumps(img))
    elif cmd == "export":
        export(out, sys.argv[3], sys.argv[4], sys.argv[5])


main()
