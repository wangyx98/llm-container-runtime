"""mkdind.py REF OUT ENTRYPOINT PROBE : the DIND image of the lab as an OCI archive (what `ctr images import` takes), made from the Docker engine that is installed on this machine, so that
nothing has to be pulled from Docker Hub: dockerd, docker, containerd, containerd-shim-runc-v2, runc, docker-init and the shared libraries they ask for (found with ldd), a minimal /etc, the
entrypoint (static program, see entrypoint.c) and the probe (static, probe.go). One uncompressed layer, the architecture of this host. The image's command line is a dockerd with its own
socket, the overlay2 driver, no bridge and no iptables (the engineer's Docker only has to pull and run); the entrypoint is /entrypoint. Prints one JSON object: the manifest digest, the
config digest, the layer digest, the versions and the sizes, and writes OUT."""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ref, out, entrypoint, probe = sys.argv[1:5]
arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine, "amd64")
PROGRAMS = ["dockerd", "docker", "docker-proxy", "containerd", "containerd-shim-runc-v2", "runc", "docker-init"]
EXTRA_DIRS = ("/usr/libexec/docker", "/usr/local/sbin", "/usr/local/bin")
CMD = ["/usr/bin/dockerd", "--host=unix:///var/run/docker.sock", "--bridge=none", "--iptables=false", "--ip6tables=false", "--storage-driver=overlay2"]


def find(name):
    p = shutil.which(name)
    if p:
        return p
    for d in EXTRA_DIRS:
        if os.path.isfile(os.path.join(d, name)):
            return os.path.join(d, name)
    raise SystemExit("mkdind: %s not found (the Docker engine must be installed)" % name)


def libs_of(path):
    r = subprocess.run(["ldd", path], capture_output=True, text=True)
    return set(re.findall(r"(/\S+\.so[\w.\-]*)", r.stdout))


def add_file(t, name, src, mode):
    ti = tarfile.TarInfo(name)
    data = open(src, "rb")
    ti.size, ti.mtime, ti.mode, ti.uid, ti.gid = os.path.getsize(src), 1700000000, mode, 0, 0
    t.addfile(ti, data)
    data.close()


def add_dir(t, name, mode=0o755):
    ti = tarfile.TarInfo(name)
    ti.type, ti.mtime, ti.mode, ti.uid, ti.gid = tarfile.DIRTYPE, 1700000000, mode, 0, 0
    t.addfile(ti)


def add_bytes(t, name, data, mode=0o644):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mtime, ti.mode, ti.uid, ti.gid = len(data), 1700000000, mode, 0, 0
    t.addfile(ti, io.BytesIO(data))


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    tmp = tempfile.mkdtemp(prefix="mkdind-")
    try:
        layer_path = os.path.join(tmp, "layer.tar")
        libs, seen = set(), set()
        with tarfile.open(layer_path, "w", format=tarfile.PAX_FORMAT) as t:
            for d in ("usr", "usr/bin", "etc", "tmp", "var", "var/lib", "var/lib/docker", "var/run", "run", "dev", "proc", "sys", "lib", "lib64"):
                add_dir(t, d, 0o1777 if d == "tmp" else 0o755)
            versions = {}
            for prog in PROGRAMS:
                p = find(prog)
                add_file(t, "usr/bin/" + prog, p, 0o755)
                libs |= libs_of(p)
                versions[prog] = hashlib.sha256(open(p, "rb").read()).hexdigest()[:12]
            add_file(t, "entrypoint", entrypoint, 0o755)
            add_file(t, "probe", probe, 0o755)
            made = {"lib", "lib64"}
            for l in sorted(libs):
                parts = l.strip("/").split("/")
                for i in range(1, len(parts)):
                    d = "/".join(parts[:i])
                    if d not in made:
                        made.add(d)
                        add_dir(t, d)
                add_file(t, l.strip("/"), os.path.realpath(l), 0o755)
            add_bytes(t, "etc/passwd", b"root:x:0:0:root:/root:/bin/false\n")
            add_bytes(t, "etc/group", b"root:x:0:\n")
        layer_digest = sha(layer_path)
        layer_size = os.path.getsize(layer_path)
        config = json.dumps({"architecture": arch, "os": "linux", "created": "2023-11-14T22:13:20Z",
                             "config": {"Entrypoint": ["/entrypoint"], "Cmd": CMD, "Env": ["PATH=/usr/bin"], "WorkingDir": "/"},
                             "rootfs": {"type": "layers", "diff_ids": ["sha256:" + layer_digest]},
                             "history": [{"created": "2023-11-14T22:13:20Z", "created_by": "bench78821163 mkdind.py: the Docker engine of this machine"}]}, sort_keys=True).encode()
        config_digest = hashlib.sha256(config).hexdigest()
        manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                               "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:" + config_digest, "size": len(config)},
                               "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": "sha256:" + layer_digest, "size": layer_size}]}, sort_keys=True).encode()
        manifest_digest = hashlib.sha256(manifest).hexdigest()
        index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:" + manifest_digest, "size": len(manifest),
                                                               "annotations": {"io.containerd.image.name": ref, "org.opencontainers.image.ref.name": ref.rsplit(":", 1)[-1]}}]}).encode()
        with tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as t:
            add_bytes(t, "oci-layout", b'{"imageLayoutVersion":"1.0.0"}')
            add_bytes(t, "index.json", index)
            add_dir(t, "blobs")
            add_dir(t, "blobs/sha256")
            add_bytes(t, "blobs/sha256/" + manifest_digest, manifest)
            add_bytes(t, "blobs/sha256/" + config_digest, config)
            add_file(t, "blobs/sha256/" + layer_digest, layer_path, 0o644)
        print(json.dumps({"ref": ref, "manifest": "sha256:" + manifest_digest, "config": "sha256:" + config_digest, "layer": "sha256:" + layer_digest, "layer_size": layer_size,
                          "programs": versions, "arch": arch}))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


main()
