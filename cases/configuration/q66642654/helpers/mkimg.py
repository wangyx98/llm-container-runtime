"""mkimg.py push BASEURL REPO TAG BINARY ENTRY [SALT] : build a Docker image (one layer with BINARY as /ENTRY and, when SALT is given, a file /salt holding it: a new SALT is
a new image with new digests) and push it to the registry with the plain distribution API (what `docker push` does)
   mkimg.py tar OUT REF BINARY ENTRY [SALT]          : build the same into an OCI archive (for ctr images import)
Prints the digests as JSON."""
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile
import urllib.request

DOCKER_MANIFEST = "application/vnd.docker.distribution.manifest.v2+json"
DOCKER_CONFIG = "application/vnd.docker.container.image.v1+json"
DOCKER_LAYER = "application/vnd.docker.image.rootfs.diff.tar.gzip"
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")


def sha(b):
    return "sha256:" + hashlib.sha256(b).hexdigest()


def build(binary, entry, salt=""):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        data = open(binary, "rb").read()
        ti = tarfile.TarInfo(entry)
        ti.size, ti.mode, ti.mtime = len(data), 0o755, 1700000000
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        t.addfile(ti, io.BytesIO(data))
        if salt:
            sd = (salt + "\n").encode()
            si = tarfile.TarInfo("salt")
            si.size, si.mode, si.mtime = len(sd), 0o644, 1700000000
            si.uid = si.gid = 0
            si.uname = si.gname = ""
            t.addfile(si, io.BytesIO(sd))
    layer = buf.getvalue()
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
        g.write(layer)
    layer_gz = gz.getvalue()               # Docker layers are gzip: blob digest != diff id
    config = json.dumps({
        "architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z", "docker_version": "20.10.21",
        "config": {"Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
                   "Entrypoint": ["/" + entry], "Cmd": [], "WorkingDir": "/"},
        "container_config": {"Cmd": ["/bin/sh", "-c", "#(nop) ", "ENTRYPOINT [\"/%s\"]" % entry]},
        "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY %s / # buildkit" % entry},
                    {"created": "2023-11-14T22:13:20Z", "created_by": "ENTRYPOINT [\"/%s\"]" % entry,
                     "empty_layer": True}],
        "rootfs": {"type": "layers", "diff_ids": [sha(layer)]}}, separators=(",", ":")).encode()
    manifest = json.dumps({"schemaVersion": 2, "mediaType": DOCKER_MANIFEST,
                           "config": {"mediaType": DOCKER_CONFIG, "digest": sha(config), "size": len(config)},
                           "layers": [{"mediaType": DOCKER_LAYER, "digest": sha(layer_gz), "size": len(layer_gz)}]},
                          separators=(",", ":")).encode()
    return layer_gz, config, manifest


def truth(layer_gz, config, manifest):
    return json.dumps({"manifest": sha(manifest), "manifest_size": len(manifest), "config": sha(config),
                       "layer": sha(layer_gz), "layer_size": len(layer_gz), "media_type": DOCKER_MANIFEST})


def http(method, url, data, ctype):
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": ctype,
                                                                         "User-Agent": "docker/20.10.21 (setup)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status


mode = sys.argv[1]
if mode == "push":
    base, repo, tag, binary, entry = sys.argv[2:7]
    layer_gz, config, manifest = build(binary, entry, sys.argv[7] if len(sys.argv) > 7 else "")
    for blob in (layer_gz, config):
        assert http("POST", "%s/v2/%s/blobs/uploads/?digest=%s" % (base, repo, sha(blob)), blob,
                    "application/octet-stream") == 201
    assert http("PUT", "%s/v2/%s/manifests/%s" % (base, repo, tag), manifest, DOCKER_MANIFEST) == 201
    print(truth(layer_gz, config, manifest))
else:
    out, ref, binary, entry = sys.argv[2:6]
    layer_gz, config, manifest = build(binary, entry, sys.argv[6] if len(sys.argv) > 6 else "")
    index = json.dumps({"schemaVersion": 2, "manifests": [{
        "mediaType": DOCKER_MANIFEST, "digest": sha(manifest), "size": len(manifest),
        "annotations": {"io.containerd.image.name": ref,
                        "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[1]}}]}).encode()
    with tarfile.open(out, "w") as t:
        def add(name, data):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime = len(data), 1700000000
            t.addfile(ti, io.BytesIO(data))
        add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
        add("index.json", index)
        for dg, data in ((sha(layer_gz), layer_gz), (sha(config), config), (sha(manifest), manifest)):
            add("blobs/sha256/" + dg.split(":")[1], data)
    print(truth(layer_gz, config, manifest))
