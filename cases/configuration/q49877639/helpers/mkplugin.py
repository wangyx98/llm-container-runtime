#!/usr/bin/env python3
"""mkplugin.py SRC [VERSION_FILE] : builds the plugin directory SRC of q49877639 (config.json + rootfs/) from the machine's own files, offline.

The rootfs is a small Debian-style userland: the host's systemd (+ systemd-executor, systemctl, the targets), a shell (dash), mount and mkdir, every library they load (found with ldd) and
/plugin, a static volume-driver server (plugin.c) that the unit plugin.service starts. config.json and the unit are the asker's: systemd as the entrypoint, /sys/fs/cgroup mounted read-only
from the host, the socket in /run/docker/plugins. The version of systemd is written to VERSION_FILE (if given) for the oracle."""
import json
import os
import shutil
import subprocess
import sys

BINS = ["/usr/lib/systemd/systemd", "/usr/lib/systemd/systemd-executor", "/usr/bin/systemctl", "/usr/bin/dash", "/usr/bin/mount", "/usr/bin/mkdir", "/usr/bin/cat", "/usr/bin/ls"]
HERE = os.path.dirname(os.path.abspath(__file__))

CONFIG = {
    "description": "systemd in a managed plugin",
    "documentation": "https://stackoverflow.com/questions/49877639",
    "entrypoint": ["/usr/lib/systemd/systemd"],
    "workdir": "/",
    "interface": {"types": ["docker.volumedriver/1.0"], "socket": "sysd.sock"},
    "linux": {"capabilities": ["CAP_SYS_ADMIN", "CAP_SYS_PTRACE", "CAP_NET_ADMIN", "CAP_MKNOD"], "allowAllDevices": False},
    "network": {"type": "host"},
    "env": [{"name": "container", "value": "docker", "settable": []}],
    "mounts": [{"destination": "/sys/fs/cgroup", "source": "/sys/fs/cgroup", "type": "bind", "options": ["rbind", "ro", "rprivate"]}],
}

UNIT = """[Unit]
Description=volume driver of the plugin

[Service]
ExecStart=/plugin /run/docker/plugins/sysd.sock
Restart=on-failure

[Install]
WantedBy=multi-user.target
"""


def norm(path):
    """/lib/x -> /usr/lib/x where the host has the merged /usr (the rootfs gets the same top-level links)"""
    for link in ("bin", "sbin", "lib", "lib64"):
        if os.path.islink("/" + link) and path.startswith("/" + link + "/"):
            return os.path.normpath("/" + os.readlink("/" + link) + path[len(link) + 1:])
    return path


def put(root, path):
    """copies the file at PATH (symlinks resolved) into ROOT, keeping the path; a link at PATH is recreated"""
    path = norm(path)
    real = os.path.realpath(path)
    for p in (path, real):
        os.makedirs(os.path.dirname(root + p), exist_ok=True)
    if not os.path.exists(root + real):
        shutil.copy2(real, root + real)
    if real != path and not os.path.lexists(root + path):
        os.symlink(real, root + path)
    return real


def libs(path):
    out = subprocess.run(["ldd", path], capture_output=True, text=True).stdout
    found = []
    for ln in out.splitlines():
        for tok in ln.split():
            if tok.startswith("/"):
                found.append(tok)
    return found


def main(src):
    src = os.path.abspath(src)
    root = src + "/rootfs"
    os.makedirs(root, exist_ok=True)
    for d in ("dev", "proc", "sys", "run", "tmp", "etc/systemd/system/multi-user.target.wants", "var"):
        os.makedirs(root + "/" + d, exist_ok=True)
    for link in ("bin", "sbin", "lib", "lib64"):
        if os.path.islink("/" + link) and not os.path.lexists(root + "/" + link):
            os.symlink(os.readlink("/" + link), root + "/" + link)
    for b in BINS:
        if not os.path.exists(b):
            if b.endswith("systemd-executor"):      # systemd < 255 has none
                continue
            sys.exit("mkplugin: %s not found" % b)
        put(root, b)
        for l in libs(b):
            put(root, l)
    os.symlink("/usr/bin/dash", root + "/usr/bin/sh") if not os.path.lexists(root + "/usr/bin/sh") else None
    # the targets and slices of the host's systemd 
    sysdir = "/usr/lib/systemd/system"
    os.makedirs(root + sysdir, exist_ok=True)
    for f in os.listdir(sysdir):
        if f.endswith((".target", ".slice")) and os.path.isfile(sysdir + "/" + f):
            shutil.copy2(sysdir + "/" + f, root + sysdir + "/" + f)
    if not os.path.lexists(root + "/etc/systemd/system/default.target"):
        os.symlink(sysdir + "/multi-user.target", root + "/etc/systemd/system/default.target")
    shutil.copy2("/etc/os-release", root + "/etc/os-release")
    open(root + "/etc/machine-id", "w").close()
    open(root + "/etc/systemd/system/plugin.service", "w").write(UNIT)
    os.symlink("/etc/systemd/system/plugin.service", root + "/etc/systemd/system/multi-user.target.wants/plugin.service")
    subprocess.run(["gcc", "-static", "-O2", "-w", "-o", root + "/plugin", HERE + "/plugin.c"], check=True)
    json.dump(CONFIG, open(src + "/config.json", "w"), indent=2)
    ver = subprocess.run([root + "/usr/lib/systemd/systemd", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    if len(sys.argv) > 2:
        open(sys.argv[2], "w").write(ver + "\n")
    print("plugin directory ready: %s (%s)" % (src, ver))


if __name__ == "__main__":
    main(sys.argv[1])
