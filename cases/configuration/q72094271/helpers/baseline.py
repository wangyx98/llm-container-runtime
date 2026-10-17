"""baseline.py save|restore DIR : the places where a solution may put a core limit that is NOT the unit of the lab (PAM limits, systemd's manager defaults, sysctl files, shell profiles).
`save` records them (a file or a directory of plain files: present or absent, content, mode) below DIR; `restore` puts every one of them back exactly as recorded."""
import json
import os
import shutil
import sys

FILES = ["/etc/security/limits.conf", "/etc/systemd/system.conf", "/etc/systemd/user.conf", "/etc/sysctl.conf"]
DIRS = ["/etc/security/limits.d", "/etc/systemd/system.conf.d", "/etc/systemd/user.conf.d", "/etc/sysctl.d", "/etc/profile.d"]


def read(p):
    with open(p, "rb") as f:
        return f.read().hex(), os.stat(p).st_mode & 0o7777


def write(p, hexdata, mode):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(bytes.fromhex(hexdata))
    os.chmod(p, mode)


def save(d):
    rec = {"files": {}, "dirs": {}}
    for p in FILES:
        rec["files"][p] = list(read(p)) if os.path.isfile(p) else None
    for p in DIRS:
        rec["dirs"][p] = {n: list(read(os.path.join(p, n))) for n in sorted(os.listdir(p)) if os.path.isfile(os.path.join(p, n))} if os.path.isdir(p) else None
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "baseline.json"), "w") as f:
        json.dump(rec, f)


def restore(d):
    with open(os.path.join(d, "baseline.json")) as f:
        rec = json.load(f)
    for p, v in rec["files"].items():
        if v is None:
            if os.path.lexists(p):
                os.remove(p)
        elif not os.path.isfile(p) or read(p) != tuple(v):
            write(p, v[0], v[1])
    for p, items in rec["dirs"].items():
        if items is None:
            shutil.rmtree(p, ignore_errors=True)
            continue
        os.makedirs(p, exist_ok=True)
        for n in os.listdir(p):
            if n not in items:
                q = os.path.join(p, n)
                shutil.rmtree(q, ignore_errors=True) if os.path.isdir(q) and not os.path.islink(q) else os.remove(q)
        for n, v in items.items():
            q = os.path.join(p, n)
            if not os.path.isfile(q) or read(q) != tuple(v):
                write(q, v[0], v[1])


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] in ("save", "restore"):
    (save if sys.argv[1] == "save" else restore)(sys.argv[2])
else:
    sys.exit("usage: baseline.py save|restore DIR")
