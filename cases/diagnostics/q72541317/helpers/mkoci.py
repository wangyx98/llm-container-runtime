"""mkoci.py OUTDIR KEY REF KIND MEDIA PLATFORMS RANDSEED? : build an image offline, as an OCI image layout archive that `ctr images import` takes, and
record what is in it.

  mkoci.py STATE KEY REF KIND MEDIA PLATFORMS      (STATE = the lab's .bench directory)
    KEY        short name of the image in the lab's records (STATE/images/KEY.json), also the archive name STATE/KEY.tar
    REF        the image name (io.containerd.image.name of the archive's entry), e.g. bench72541317.local/app:1
    KIND       index: a multi-platform image (its top-level content is an index); manifest: a single-platform one (a manifest)
    MEDIA      oci | docker: the media types of its index, manifests, config and layers (docker: manifest list v2, manifest v2, ...)
    PLATFORMS  comma separated, like linux/amd64,linux/arm64,linux/arm/v7 (exactly one for KIND manifest)

Every image gets fresh random content. Each platform has its own config and manifest, a layer shared by all platforms and a layer of its own. Every
JSON document is written with indent 3 (like the registries' own), so that it is not what a re-serialization by jq or json.tool gives back.
The blobs are also written to STATE/blobs/<hex>, and the record (STATE/images/KEY.json) has: ref, kind, media, target (the digest of the top-level
descriptor of the image), and per platform: manifest, config, layers (digests)."""
import gzip
import hashlib
import io
import json
import os
import random
import sys
import tarfile
import time

state, key, ref, kind, media, platforms = sys.argv[1:7]
R = random.SystemRandom()
M = {"oci": {"index": "application/vnd.oci.image.index.v1+json", "manifest": "application/vnd.oci.image.manifest.v1+json",
             "config": "application/vnd.oci.image.config.v1+json", "layer": "application/vnd.oci.image.layer.v1.tar+gzip"},
     "docker": {"index": "application/vnd.docker.distribution.manifest.list.v2+json", "manifest": "application/vnd.docker.distribution.manifest.v2+json",
                "config": "application/vnd.docker.container.image.v1+json", "layer": "application/vnd.docker.image.rootfs.diff.tar.gzip"}}[media]
blobs = {}


def put(data, mt):
    h = hashlib.sha256(data).hexdigest()
    blobs[h] = data
    return {"mediaType": mt, "digest": "sha256:" + h, "size": len(data)}


def dump(d):
    return json.dumps(d, indent=2).encode()


def layer(marker):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        body = (marker + "\n").encode()
        ti = tarfile.TarInfo("etc/" + marker.split("-")[0])
        ti.size = len(body)
        ti.mtime = 1700000000
        t.addfile(ti, io.BytesIO(body))
    raw = buf.getvalue()
    gz = io.BytesIO()
    with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
        g.write(raw)
    return gz.getvalue(), "sha256:" + hashlib.sha256(raw).hexdigest()


hx = lambda n: "".join(R.choices("0123456789abcdef", k=n))
shared_gz, shared_diff = layer("base-" + hx(16))
rec = {"ref": ref, "kind": kind, "media": media, "platforms": {}}
descs = []
for p in platforms.split(","):
    parts = p.split("/")
    os_, arch = parts[0], parts[1]
    variant = parts[2] if len(parts) > 2 else None
    own_gz, own_diff = layer("plat-%s-%s" % (arch, hx(16)))
    plat = {"architecture": arch, "os": os_}
    if variant:
        plat["variant"] = variant
    cfg = dump({**plat, "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(1700000000 + R.randint(0, 10 ** 7))),
                "config": {"Env": ["MARKER=" + hx(12)], "Cmd": ["/bin/true"]},
                "rootfs": {"type": "layers", "diff_ids": [shared_diff, own_diff]},
                "history": [{"created_by": "bench72541317 base layer"}, {"created_by": "bench72541317 layer of " + p}]})
    cdesc = put(cfg, M["config"])
    ldescs = [put(shared_gz, M["layer"]), put(own_gz, M["layer"])]
    man = dump({"schemaVersion": 2, "mediaType": M["manifest"], "config": cdesc, "layers": ldescs})
    mdesc = put(man, M["manifest"])
    descs.append({**mdesc, "platform": plat})
    rec["platforms"][p] = {"manifest": mdesc["digest"], "config": cdesc["digest"], "layers": [d["digest"] for d in ldescs]}
if kind == "index":
    top = put(dump({"schemaVersion": 2, "mediaType": M["index"], "manifests": descs}), M["index"])
else:
    assert len(descs) == 1
    top = {k: descs[0][k] for k in ("mediaType", "digest", "size")}
rec["target"] = top["digest"]
os.makedirs(state + "/blobs", exist_ok=True)
os.makedirs(state + "/images", exist_ok=True)
for h, d in blobs.items():
    open(state + "/blobs/" + h, "wb").write(d)
json.dump(rec, open("%s/images/%s.json" % (state, key), "w"), indent=1)

layout_index = dump({"schemaVersion": 2, "manifests": [{**top, "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[-1]}}]})
with tarfile.open("%s/%s.tar" % (state, key), "w") as t:
    def add(name, data):
        ti = tarfile.TarInfo(name)
        ti.size = len(data)
        ti.mtime = 1700000000
        t.addfile(ti, io.BytesIO(data))
    add("oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
    add("index.json", layout_index)
    for h, d in blobs.items():
        add("blobs/sha256/" + h, d)
print(json.dumps({"key": key, "target": rec["target"]}))
