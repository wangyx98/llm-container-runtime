#!/usr/bin/env python3
"""mkimage.py ROOT REPO TAG [--layers SIZE:SECONDS,...] [--corrupt N] : add an image to the registry directory ROOT (see registry.py).

Each layer is one file of random bytes, tarred and gzipped; the layers are SIZE bytes of data each, and are served at a rate at which the
transfer takes about SECONDS. --corrupt N flips one byte of the blob of layer N (counted from 0) AFTER its digest was taken, so the blob
no longer matches its digest: the download goes through, the pull must fail when containerd verifies it. Prints the image as JSON.
"""
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def put(root, data, rate=None):
    h = sha(data)
    os.makedirs(os.path.join(root, "blobs"), exist_ok=True)
    open(os.path.join(root, "blobs", h), "wb").write(data)
    if rate:
        os.makedirs(os.path.join(root, "rates"), exist_ok=True)
        open(os.path.join(root, "rates", h), "w").write("%.1f" % rate)
    return "sha256:" + h


def main():
    root, repo, tag = sys.argv[1:4]
    opts = sys.argv[4:]
    layers, corrupt = [], None
    while opts:
        if opts[0] == "--layers":
            layers = [(int(s), float(t)) for s, t in (x.split(":") for x in opts[1].split(","))]
            opts = opts[2:]
        elif opts[0] == "--corrupt":
            corrupt = int(opts[1])
            opts = opts[2:]
        else:
            sys.exit("unknown option " + opts[0])
    out_layers, diff_ids = [], []
    for i, (size, seconds) in enumerate(layers):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as t:
            ti = tarfile.TarInfo("data-%d.bin" % i)
            ti.size, ti.mode, ti.mtime = size, 0o644, 1700000000
            t.addfile(ti, io.BytesIO(os.urandom(size)))
        tar_bytes = raw.getvalue()
        diff_ids.append("sha256:" + sha(tar_bytes))
        gzipped = io.BytesIO()
        with gzip.GzipFile(fileobj=gzipped, mode="wb", compresslevel=1, mtime=0) as g:
            g.write(tar_bytes)
        blob = gzipped.getvalue()
        digest = "sha256:" + sha(blob)
        stored = blob
        if corrupt == i:
            mid = len(blob) // 2
            stored = blob[:mid] + bytes([blob[mid] ^ 0xFF]) + blob[mid + 1:]
        os.makedirs(os.path.join(root, "blobs"), exist_ok=True)
        os.makedirs(os.path.join(root, "rates"), exist_ok=True)
        # the blob is stored under the digest it should have: for a corrupted layer that is not the digest of its bytes
        open(os.path.join(root, "blobs", digest.split(":")[1]), "wb").write(stored)
        rate = len(blob) / seconds
        open(os.path.join(root, "rates", digest.split(":")[1]), "w").write("%.1f" % rate)
        out_layers.append({"digest": digest, "size": len(blob), "diff_id": diff_ids[-1], "seconds": seconds, "rate": rate})
    config = json.dumps({"architecture": arch, "os": "linux", "config": {},
                         "rootfs": {"type": "layers", "diff_ids": diff_ids}}).encode()
    config_digest = put(root, config)
    manifest = json.dumps({
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": len(config)},
        "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": l["digest"], "size": l["size"]}
                   for l in out_layers],
    }).encode()
    manifest_digest = put(root, manifest)
    os.makedirs(os.path.join(root, "tags", repo), exist_ok=True)
    open(os.path.join(root, "tags", repo, tag), "w").write(manifest_digest)
    print(json.dumps({"repo": repo, "tag": tag, "manifest": {"digest": manifest_digest, "size": len(manifest)},
                      "config": {"digest": config_digest, "size": len(config)}, "layers": out_layers,
                      "corrupt": corrupt}))


main()
