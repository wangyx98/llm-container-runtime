"""mkbase.py CA_PEM OUT_TAR REF : the base image of the lab (it replaces openjdk / adoptopenjdk, which a machine without a registry cannot pull): a root file system made of the tools of THIS
machine (bash as sh, curl, unzip, sha256sum and the coreutils that gradlew and bin/gradle use, with the shared libraries they need and the name service libraries), the lab's CA as
the only trusted certificate authority, and a root user. OUT_TAR is an OCI archive with ONE layer whose image name is REF (nerdctl load takes it). Prints the manifest digest."""
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

ca_pem, out, ref = sys.argv[1:4]
arch = {"x86_64": "amd64", "aarch64": "arm64"}[os.uname().machine]
TOOLS = "bash curl unzip sha256sum cat ls sed cp mkdir rm mv chmod head tail tr cut grep sort find xargs date env sleep wc dirname basename tee id".split()

root = tempfile.mkdtemp(prefix="mkbase")


def put(src, dst=None):
    dst = os.path.join(root, (dst or src).lstrip("/"))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not os.path.exists(dst):
        shutil.copy2(src, dst)


libdir = None
for t in TOOLS:
    p = shutil.which(t)
    if not p:
        sys.exit("mkbase: %s is not installed on this machine" % t)
    put(os.path.realpath(p), "/usr/bin/" + t)
    for line in subprocess.run(["ldd", p], capture_output=True, text=True).stdout.splitlines():
        for w in line.split():
            if w.startswith("/") and os.path.exists(w):
                put(os.path.realpath(w), w)
                if os.path.basename(w).startswith("libc.so"):
                    libdir = os.path.dirname(w)
os.symlink("usr/bin", os.path.join(root, "bin"))
os.symlink("bash", os.path.join(root, "usr/bin/sh"))
for lib in ("libnss_files.so.2", "libnss_dns.so.2", "libresolv.so.2"):
    if libdir and os.path.exists(os.path.join(libdir, lib)):
        put(os.path.realpath(os.path.join(libdir, lib)), os.path.join(libdir, lib))
for d in ("tmp", "root", "workspace", "proc", "sys", "dev", "etc/ssl/certs"):
    os.makedirs(os.path.join(root, d), exist_ok=True)
os.chmod(os.path.join(root, "tmp"), 0o1777)
open(os.path.join(root, "etc/passwd"), "w").write("root:x:0:0:root:/root:/bin/sh\n")
open(os.path.join(root, "etc/group"), "w").write("root:x:0:\n")
open(os.path.join(root, "etc/nsswitch.conf"), "w").write("hosts: files dns\n")
shutil.copy(ca_pem, os.path.join(root, "etc/ssl/certs/ca-certificates.crt"))

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
    for dp, dn, fn in sorted(os.walk(root)):
        dn.sort()
        for n in sorted(dn + fn):
            p = os.path.join(dp, n)
            ti = t.gettarinfo(p, os.path.relpath(p, root))
            ti.mtime, ti.uid, ti.gid, ti.uname, ti.gname = 1700000000, 0, 0, "", ""
            if ti.isreg():
                with open(p, "rb") as f:
                    t.addfile(ti, f)
            else:
                t.addfile(ti)
shutil.rmtree(root)
layer = buf.getvalue()
sha = lambda b: hashlib.sha256(b).hexdigest()
ld = sha(layer)
cfg = json.dumps({"architecture": arch, "os": "linux", "config": {"Cmd": ["/bin/sh"], "Env": ["PATH=/usr/local/bin:/usr/bin:/bin"]}, "rootfs": {"type": "layers", "diff_ids": ["sha256:" + ld]},
                  "history": [{"created_by": "bench70704948 base"}]}, sort_keys=True).encode()
cd = sha(cfg)
man = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:" + cd,
                  "size": len(cfg)}, "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": "sha256:" + ld, "size": len(layer)}]}, sort_keys=True).encode()
md = sha(man)
idx = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:" + md, "size": len(man),
                  "annotations": {"io.containerd.image.name": ref}}]}).encode()
with tarfile.open(out, "w") as t:
    for n, d in (("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'), ("index.json", idx), ("blobs/sha256/" + md, man), ("blobs/sha256/" + cd, cfg), ("blobs/sha256/" + ld, layer)):
        ti = tarfile.TarInfo(n)
        ti.size = len(d)
        t.addfile(ti, io.BytesIO(d))
print("sha256:" + md)
