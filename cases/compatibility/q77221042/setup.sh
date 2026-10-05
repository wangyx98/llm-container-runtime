#!/bin/bash
set -e

CASE_ID="bench77221042"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/$CASE_ID"
STATE_DIR="$WORK_DIR/.bench"
BUNDLE="$WORK_DIR/bundle"
ROOTFS="$BUNDLE/rootfs"
REPO="$WORK_DIR/repo"
PKG="bench77221042-hello"
CONTAINER="$CASE_ID"

echo "[setup] checking runc, python3 and the dpkg/apt tools the container's root file system is built from..."
command -v runc >/dev/null || { echo "[setup] ERROR: runc not found"; exit 1; }
command -v python3 >/dev/null || { echo "[setup] ERROR: python3 not found"; exit 1; }
for t in apt-get dpkg dpkg-deb dpkg-query ldd; do
    command -v "$t" >/dev/null || { echo "[setup] ERROR: $t not found on the host"; exit 1; }
done
# The container's root file system is a small copy of the host's dpkg/apt user-land (a Debian
# family system), so /bin, /sbin and /lib have to be links into /usr here.
for d in bin sbin lib; do
    [ -L "/$d" ] || { echo "[setup] ERROR: /$d is not a link into /usr on this host (merged-/usr layout needed)"; exit 1; }
done
runc --version | head -n 1

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

echo "[setup] resetting work dir..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$STATE_DIR" "$REPO" "$BUNDLE"

TOK=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
echo "$TOK" > "$STATE_DIR/token"

echo "[setup] building the test package $PKG (one script, /usr/bin/$PKG)..."
PKGDIR="$STATE_DIR/pkg"
mkdir -p "$PKGDIR/DEBIAN" "$PKGDIR/usr/bin"
cat > "$PKGDIR/DEBIAN/control" <<CTL
Package: $PKG
Version: 1.0-1
Architecture: all
Maintainer: bench <bench@localhost>
Section: misc
Priority: optional
Description: package used by the benchmark case $CASE_ID
 Installs one script that prints a line.
CTL
printf '#!/bin/sh\necho "hello from %s %s"\n' "$CASE_ID" "$TOK" > "$PKGDIR/usr/bin/$PKG"
chmod 0755 "$PKGDIR/usr/bin/$PKG"
dpkg-deb --build -Zgzip --root-owner-group "$PKGDIR" "$REPO/${PKG}_1.0-1_all.deb" >/dev/null

echo "[setup] writing the local package source (a flat apt repository with Packages and Release)..."
python3 - "$REPO" "$PKG" <<'PYEOF'
import hashlib
import os
import subprocess
import sys
import time

repo, pkg = sys.argv[1:3]
deb = "%s_1.0-1_all.deb" % pkg
path = os.path.join(repo, deb)
data = open(path, "rb").read()
control = subprocess.run(["dpkg-deb", "-f", path], capture_output=True, text=True, check=True).stdout.rstrip("\n")
stanza = "%s\nFilename: ./%s\nSize: %d\nMD5sum: %s\nSHA256: %s\n" % (
    control, deb, len(data), hashlib.md5(data).hexdigest(), hashlib.sha256(data).hexdigest())
packages = stanza.encode()
open(os.path.join(repo, "Packages"), "wb").write(packages)
release = (
    "Origin: bench77221042\nLabel: bench77221042\nSuite: stable\nCodename: bench\n"
    "Date: %s\nArchitectures: all\nDescription: local repository of the benchmark case bench77221042\n"
    "SHA256:\n %s %d Packages\n" % (
        time.strftime("%a, %d %b %Y %H:%M:%S UTC", time.gmtime()),
        hashlib.sha256(packages).hexdigest(), len(packages)))
open(os.path.join(repo, "Release"), "w").write(release)
PYEOF
chmod -R a+rX "$REPO"

echo "[setup] building the root file system (dpkg, apt and a small shell user-land copied from the host)..."
sudo python3 - "$ROOTFS" "$PKG" <<'PYEOF'
import os
import shutil
import subprocess
import sys

root, pkg = sys.argv[1:3]
done = set()


def dst(p):
    return os.path.join(root, p.lstrip("/"))


def copy(p):
    """copy file or link p (and what a link points to, and the libraries of a program)"""
    d, b = os.path.split(p)
    p = os.path.join(os.path.realpath(d), b)
    if p in done or not os.path.lexists(p):
        return
    done.add(p)
    os.makedirs(os.path.dirname(dst(p)), exist_ok=True)
    if os.path.islink(p):
        t = os.readlink(p)
        if os.path.lexists(dst(p)):
            os.remove(dst(p))
        os.symlink(t, dst(p))
        copy(t if os.path.isabs(t) else os.path.normpath(os.path.join(os.path.dirname(p), t)))
    elif os.path.isfile(p):
        shutil.copy2(p, dst(p))
        with open(p, "rb") as f:
            magic = f.read(4)
        if magic == b"\x7fELF":
            out = subprocess.run(["ldd", p], capture_output=True, text=True).stdout
            for tok in out.split():
                if tok.startswith("/") and tok != p:
                    copy(tok)


def copy_tree(top):
    for dp, dns, fns in os.walk(top):
        os.makedirs(dst(dp), exist_ok=True)
        for fn in fns:
            copy(os.path.join(dp, fn))


os.makedirs(root, exist_ok=True)
for name in ("bin", "sbin", "lib", "lib64", "lib32", "libx32"):
    if os.path.islink("/" + name):
        os.symlink(os.readlink("/" + name), os.path.join(root, name))

programs = """apt-get apt apt-cache apt-config dpkg dpkg-deb dpkg-query dpkg-divert dpkg-trigger dpkg-statoverride
update-alternatives sh dash bash sleep cat ls mkdir rmdir rm cp mv ln chmod chown touch id whoami env stat uname date
tail head tr readlink dirname basename cut sort wc tee true false printf test [ grep sed awk tar gzip find mount df
echo hostname diff ldconfig start-stop-daemon dpkg-split""".split()
for prog in programs:
    path = shutil.which(prog, path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    if path:
        copy(path)

for top in ("/usr/lib/apt", "/usr/lib/dpkg", "/usr/share/dpkg", "/etc/dpkg"):
    if os.path.isdir(top):
        copy_tree(top)
# names the C library looks up at run time (getpwnam, ...) and the loader cache
for dp, dns, fns in os.walk("/usr/lib"):
    for fn in fns:
        if fn.startswith("libnss_files") or fn.startswith("libnss_compat"):
            copy(os.path.join(dp, fn))
copy("/etc/ld.so.cache")
copy("/etc/ld.so.conf")
if os.path.isdir("/etc/ld.so.conf.d"):
    copy_tree("/etc/ld.so.conf.d")

for d in ("proc", "sys", "dev", "tmp", "run", "root", "opt", "srv/bench-repo", "mnt", "var/tmp", "var/log/apt",
          "var/lib/dpkg/info", "var/lib/dpkg/updates", "var/lib/dpkg/triggers", "var/lib/dpkg/alternatives",
          "var/lib/apt/lists", "var/cache/apt/archives", "etc/apt/apt.conf.d", "etc/apt/sources.list.d",
          "etc/apt/preferences.d", "etc/apt/trusted.gpg.d", "usr/local/bin", "usr/local/lib", "usr/local/share"):
    os.makedirs(os.path.join(root, d), exist_ok=True)
os.chmod(os.path.join(root, "tmp"), 0o1777)
os.chmod(os.path.join(root, "var/tmp"), 0o1777)


def write(rel, text):
    with open(os.path.join(root, rel), "w") as f:
        f.write(text)


write("var/lib/dpkg/status", "")
write("var/lib/dpkg/available", "")
write("etc/passwd", "root:x:0:0:root:/root:/bin/sh\n_apt:x:42:65534::/nonexistent:/usr/sbin/nologin\n")
write("etc/group", "root:x:0:\nnogroup:x:65534:\n")
write("etc/nsswitch.conf", "passwd: files\ngroup: files\nhosts: files\n")
write("etc/hostname", "bench77221042\n")
write("etc/apt/sources.list", "")
write("etc/apt/sources.list.d/bench.list", "deb [trusted=yes] file:/srv/bench-repo ./\n")
write("etc/apt/apt.conf.d/99bench",
      'APT::Sandbox::User "root";\nAcquire::Languages "none";\nAPT::Install-Recommends "false";\n')
PYEOF

echo "[setup] writing the bundle's config.json: read-only root file system, the repository bind-mounted"
echo "[setup] read-only at /srv/bench-repo, init process sleep..."
(cd "$BUNDLE" && runc spec)
python3 - "$BUNDLE/config.json" "$REPO" "$CONTAINER" <<'PYEOF'
import json
import sys

path, repo, name = sys.argv[1:4]
cfg = json.load(open(path))
cfg["process"]["terminal"] = False
cfg["process"]["args"] = ["/usr/bin/sleep", "3600"]
cfg["root"] = {"path": "rootfs", "readonly": True}
cfg["hostname"] = name
cfg["mounts"].append({"destination": "/srv/bench-repo", "type": "bind", "source": repo,
                      "options": ["rbind", "ro"]})
json.dump(cfg, open(path, "w"), indent=2)
PYEOF

echo "[setup] starting the container $CONTAINER with runc (default runc root)..."
(cd "$BUNDLE" && timeout -k 5 60 sudo runc run -d --bundle "$BUNDLE" --pid-file "$STATE_DIR/init.pid" "$CONTAINER" \
    </dev/null >"$STATE_DIR/runc.log" 2>&1) || { echo "[setup] ERROR: runc run failed:"; cat "$STATE_DIR/runc.log"; exit 1; }
for _ in $(seq 1 20); do
    sudo runc state "$CONTAINER" 2>/dev/null | grep -q '"status": "running"' && break
    sleep 0.5
done
sudo runc state "$CONTAINER" 2>/dev/null | grep -q '"status": "running"' || { echo "[setup] ERROR: the container is not running"; exit 1; }

echo "[setup] done. Container $CONTAINER runs from $BUNDLE with a read-only root file system."
