#!/bin/bash
# Reference: back up web with everything the container is made of (the image, docker inspect, the writable layer's file, the volume's files, the bind-mounted file)
# into /var/backups/bench45937714, with a restore.sh that rebuilds the container from that directory on any docker daemon pointed to by DOCKER_HOST.
set -euo pipefail

export DOCKER_HOST=unix:///run/bench45937714/src.sock
BACKUP=/var/backups/bench45937714

sudo rm -rf "$BACKUP"
sudo mkdir -p "$BACKUP"
sudo -E sh -c "
set -e
cd $BACKUP
docker inspect web > inspect.json
IMG=\$(docker inspect -f '{{.Config.Image}}' web)
docker save \"\$IMG\" -o image.tar
docker cp web:/data/. - > data.tar
docker cp web:/var/lib/marker.txt - > marker.tar
docker cp web:/etc/app.conf - > conf.tar
"

sudo tee "$BACKUP/restore.sh" > /dev/null <<'RESTORE'
#!/bin/bash
# Rebuilds the container web on the docker daemon of DOCKER_HOST from the files next to this script.
set -euo pipefail
cd "$(dirname "$0")"
docker load -i image.tar
python3 - <<'PY'
import json, os, subprocess, tarfile

def docker(*a, **kw):
    return subprocess.run(["docker"] + list(a), check=True, **kw)

c = json.load(open("inspect.json"))[0]
cfg, host = c["Config"], c["HostConfig"]
name = c["Name"].lstrip("/")
args = ["create", "--name", name, "--restart", host["RestartPolicy"]["Name"], "-w", cfg["WorkingDir"]]
for e in cfg["Env"]:
    args += ["-e", e]
for k, v in (cfg.get("Labels") or {}).items():
    if not k.startswith("org.opencontainers"):
        args += ["--label", "%s=%s" % (k, v)]
for port, binds in (host["PortBindings"] or {}).items():
    for b in binds:
        args += ["-p", "%s:%s:%s" % (b["HostIp"], b["HostPort"], port.split("/")[0])]
for m in c["Mounts"]:
    if m["Type"] == "volume":
        docker("volume", "create", m["Name"], stdout=subprocess.DEVNULL)
        args += ["-v", "%s:%s" % (m["Name"], m["Destination"])]
    elif m["Type"] == "bind":
        os.makedirs(os.path.dirname(m["Source"]), exist_ok=True)
        with tarfile.open("conf.tar") as t:
            member = t.getmembers()[0]
            open(m["Source"], "wb").write(t.extractfile(member).read())
        args += ["-v", "%s:%s%s" % (m["Source"], m["Destination"], "" if m["RW"] else ":ro")]
for net, n in c["NetworkSettings"]["Networks"].items():
    if net in ("bridge", "host", "none"):
        continue
    if subprocess.run(["docker", "network", "inspect", net], capture_output=True).returncode != 0:
        docker("network", "create", net, stdout=subprocess.DEVNULL)
    args += ["--network", net]
    for a in n.get("Aliases") or []:
        if not c["Id"].startswith(a) and a != name:
            args += ["--network-alias", a]
args += [cfg["Image"]] + cfg["Cmd"]
docker(*args, stdout=subprocess.DEVNULL)
docker("cp", "-", name + ":/data", stdin=open("data.tar", "rb"))
docker("cp", "-", name + ":/var/lib", stdin=open("marker.tar", "rb"))
docker("start", name, stdout=subprocess.DEVNULL)
PY
RESTORE
sudo chmod +x "$BACKUP/restore.sh"
ls -l "$BACKUP"
