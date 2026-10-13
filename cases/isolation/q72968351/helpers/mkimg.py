"""mkimg.py REF PROGRAM SALT OUT : an image (one layer: the static program /podmark and /etc/marker-salt holding SALT; CMD /podmark) as a `docker save` archive OUT that
`ctr images import OUT` takes. REF is the name it gets. Prints {"ref", "image_id", "layer"} as JSON."""
import hashlib, io, json, os, sys, tarfile

ref, prog, salt, out = sys.argv[1:5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
sha = lambda b: hashlib.sha256(b).hexdigest()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for name, data, mode in (("etc/", None, 0o755), ("etc/marker-salt", (salt + "\n").encode(), 0o644), ("podmark", open(prog, "rb").read(), 0o755)):
        ti = tarfile.TarInfo(name)
        ti.mtime, ti.mode = 1700000000, mode
        if data is None:
            ti.type = tarfile.DIRTYPE
            t.addfile(ti)
        else:
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
layer = buf.getvalue()
config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                     "config": {"Env": ["PATH=/"], "Cmd": ["/podmark"], "WorkingDir": "/"},
                     "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "COPY podmark /podmark"}],
                     "rootfs": {"type": "layers", "diff_ids": ["sha256:" + sha(layer)]}}, separators=(",", ":")).encode()
manifest = json.dumps([{"Config": sha(config) + ".json", "RepoTags": [ref], "Layers": [sha(layer) + "/layer.tar"]}]).encode()
with tarfile.open(out, "w") as t:
    for name, data in (("manifest.json", manifest), (sha(config) + ".json", config), (sha(layer) + "/layer.tar", layer)):
        ti = tarfile.TarInfo(name)
        ti.size, ti.mtime = len(data), 1700000000
        t.addfile(ti, io.BytesIO(data))
print(json.dumps({"ref": ref, "image_id": "sha256:" + sha(config), "layer": "sha256:" + sha(layer)}))
