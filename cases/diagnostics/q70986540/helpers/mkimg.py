"""mkimg.py REF VARIANT CREATED OUT : build a small Docker-format image into an OCI archive OUT that `ctr images import` takes; REF is the name it gets.
The one layer holds a file /etc/variant with the text VARIANT, which the image config repeats as a label: two images with different VARIANTs have
different layers, configs, manifests and so different digests. CREATED is the value of the `created` field of the image config (an RFC 3339
timestamp, written as it must stay), or - for an image whose config has no `created` field at all. The config always has a history of two steps:
a base step (created 2017-03-04T05:06:07.000000008Z) and the step that adds the file (created CREATED, or a date of 2020 when the config has none),
so the history never gives the date of the `created` field. Prints the digests as JSON: the image ID of the CRI is the digest of the config."""
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile

ref, variant, created, out = sys.argv[1:5]
BASE = "2017-03-04T05:06:07.000000008Z"
STEP = "2020-02-02T02:02:02Z" if created == "-" else created
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    data = (variant + "\n").encode()
    ti = tarfile.TarInfo("etc-variant")
    ti.size, ti.mode, ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = len(data), 0o644, 1700000000, 0, 0, "", ""
    t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
diff_id = sha(layer)
gz = io.BytesIO()
with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
    g.write(layer)
layer_gz = gz.getvalue()
cfg = {"architecture": arch, "os": "linux", "docker_version": "20.10.21",
       "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"], "Cmd": ["/bin/sh"], "Labels": {"bench.variant": variant}},
       "history": [{"created": BASE, "created_by": "/bin/sh -c #(nop) base layer", "empty_layer": True},
                   {"created": STEP, "created_by": "COPY etc-variant / # buildkit"}],
       "rootfs": {"type": "layers", "diff_ids": [diff_id]}}
if created != "-":
    cfg = {"created": created, **cfg}
config = json.dumps(cfg, separators=(",", ":")).encode()
manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                       "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                       "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(layer_gz), "size": len(layer_gz)}]},
                      separators=(",", ":")).encode()
index = json.dumps({"schemaVersion": 2, "manifests": [{
    "mediaType": DOCKER_MANIFEST, "digest": sha(manifest), "size": len(manifest),
    "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
with tarfile.open(out, "w") as t:
    def add(name, data):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(data), 1700000000
        t.addfile(ti, io.BytesIO(data))
    add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
    add("index.json", index)
    for dg, d in ((sha(layer_gz), layer_gz), (sha(config), config), (sha(manifest), manifest)):
        add("blobs/sha256/" + dg.split(":")[1], d)
print(json.dumps({"ref": ref, "manifest": sha(manifest), "config": sha(config), "layer": sha(layer_gz)}))
