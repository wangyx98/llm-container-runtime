"""mkimage.py ROOT SOCI READER TAG [--arch-check] : one more image in the repository "app" of the registry blob store ROOT (what registry.py serves), converted for the SOCI snapshotter.

The image: ONE gzip layer of about 48 MiB: /reader (the static workload, first in the layer), /etc/bench-label (a random label) and twelve files of 4 MiB of random bytes, /data/dNN/sub/xNN/fNN.bin
(NN = 00..11, new random bytes for every image: nothing of an earlier image is in the layer), entrypoint /reader hold. The layer is built here, then `soci convert --standalone` makes a SOCI
image of the layout: the same layer, a SOCI index (v2: the manifest has the annotation com.amazon.soci.index-digest) with the ztoc of the layer, and an OCI index over both. The blobs are copied into
ROOT/blobs/sha256 and ROOT/tags.json gets {"app": {TAG: digest of the OCI index}}. Prints one JSON object: tag, root, manifest, index, layer, layer_size, label and the sha256 of every data file."""
import gzip
import hashlib
import io
import json
import os
import secrets
import shutil
import subprocess
import sys
import tarfile
import tempfile

root, soci, reader, tag = sys.argv[1:5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
NFILES, FSIZE = 12, 4 << 20


def put(blobs, data):
    d = hashlib.sha256(data).hexdigest()
    with open(os.path.join(blobs, d), "wb") as f:
        f.write(data)
    return "sha256:" + d


def main():
    work = tempfile.mkdtemp(prefix="mkimage-")
    try:
        src, conv = os.path.join(work, "src"), os.path.join(work, "conv")
        sblobs = os.path.join(src, "blobs", "sha256")
        os.makedirs(sblobs)
        label = "img-" + secrets.token_hex(8)
        files = {}
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
            def add(name, data, mode=0o644, dirtype=False):
                ti = tarfile.TarInfo(name)
                ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname, ti.mode = 1700000000, 0, 0, "", "", mode
                if dirtype:
                    ti.type = tarfile.DIRTYPE
                    t.addfile(ti)
                else:
                    ti.size = len(data)
                    t.addfile(ti, io.BytesIO(data))
            add("reader", open(reader, "rb").read(), 0o755)
            add("etc/", None, 0o755, True)
            add("etc/bench-label", (label + "\n").encode())
            for i in range(NFILES):
                p = "data/d%02d/sub/x%02d/f%02d.bin" % (i, i, i)
                data = secrets.token_bytes(FSIZE)
                files["/" + p] = hashlib.sha256(data).hexdigest()
                add(p, data)
        raw = buf.getvalue()
        gz = io.BytesIO()
        with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0, compresslevel=1) as g:
            g.write(raw)
        layer = gz.getvalue()
        layer_digest = put(sblobs, layer)
        config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "config": {"Entrypoint": ["/reader", "hold"], "WorkingDir": "/"},
                             "rootfs": {"type": "layers", "diff_ids": ["sha256:" + hashlib.sha256(raw).hexdigest()]},
                             "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY . /"}]}, sort_keys=True).encode()
        config_digest = put(sblobs, config)
        manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                               "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": config_digest, "size": len(config)},
                               "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": layer_digest, "size": len(layer)}]}, sort_keys=True).encode()
        mdigest = put(sblobs, manifest)
        json.dump({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": mdigest, "size": len(manifest),
                                                      "annotations": {"org.opencontainers.image.ref.name": "app"}}]}, open(os.path.join(src, "index.json"), "w"))
        open(os.path.join(src, "oci-layout"), "w").write('{"imageLayoutVersion":"1.0.0"}')
        r = subprocess.run([soci, "convert", "--standalone", "--format", "oci-dir", src, conv], capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if r.returncode != 0:
            raise SystemExit("soci convert failed: " + (r.stdout + r.stderr).strip()[-400:])
        idx = json.load(open(os.path.join(conv, "index.json")))
        top = idx["manifests"][0]["digest"]
        cblobs = os.path.join(conv, "blobs", "sha256")
        index_manifest = json.load(open(os.path.join(cblobs, top[7:])))
        soci_index = [m["digest"] for m in index_manifest["manifests"] if m.get("artifactType", "").startswith("application/vnd.amazon.soci.index")]
        if len(soci_index) != 1:
            raise SystemExit("the converted image has no SOCI index: " + json.dumps(index_manifest)[:300])
        # the converted image manifest (the one the snapshotter finds the index from) and its layer: the layer must be the very blob that was built here
        conv_manifest = [m["digest"] for m in index_manifest["manifests"] if m.get("annotations", {}).get("com.amazon.soci.index-digest") == soci_index[0]][0]
        cm = json.load(open(os.path.join(cblobs, conv_manifest[7:])))
        assert cm["layers"][0]["digest"] == layer_digest, "soci convert changed the layer"
        blobs = os.path.join(root, "blobs", "sha256")
        os.makedirs(blobs, exist_ok=True)
        for name in os.listdir(cblobs):
            dst = os.path.join(blobs, name)
            if not os.path.exists(dst):
                shutil.copyfile(os.path.join(cblobs, name), dst)
        tp = os.path.join(root, "tags.json")
        tags = json.load(open(tp)) if os.path.exists(tp) else {"app": {}}
        tags["app"][tag] = top
        json.dump(tags, open(tp + ".tmp", "w"))
        os.replace(tp + ".tmp", tp)
        print(json.dumps({"tag": tag, "root": top, "manifest": conv_manifest, "index": soci_index[0], "layer": layer_digest, "layer_size": len(layer), "label": label, "files": files}))
    finally:
        shutil.rmtree(work, ignore_errors=True)


main()
