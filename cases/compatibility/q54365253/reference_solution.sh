#!/bin/bash
set -e
# Reference solution. runc runs a bundle (config.json + rootfs) and knows nothing of Compose, so the Compose file has to be translated by a program of our own: for the fields in scope
# (command, working_dir, environment, hostname, read_only, volumes) this is a small mapping onto the default `runc spec`, whose isolation (namespaces, masked paths, capabilities) stays as it is.
# What is not trivial: the default spec is read-only and has a terminal and the command `sh` (all three are changed), environment values are not always strings (RETRIES: 3), and a relative
# volume source is relative to the directory of the COMPOSE file, while runc wants an absolute host path.
cat > /var/lib/bench54365253/compose2oci <<'PYEOF'
#!/usr/bin/env python3
import json, os, shutil, subprocess, sys, tempfile

import yaml

compose, bundle = sys.argv[1:3]
doc = yaml.safe_load(open(compose))
(name, svc), = doc["services"].items()      # one service: the scope of this converter

tmp = tempfile.mkdtemp()
try:
    subprocess.run(["runc", "spec", "-b", tmp], check=True)
    cfg = json.load(open(os.path.join(tmp, "config.json")))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

proc = cfg["process"]
proc["terminal"] = False
proc["args"] = [str(a) for a in svc["command"]]
proc["cwd"] = svc.get("working_dir", "/")
env = [e for e in proc["env"] if e.split("=", 1)[0] in ("PATH", "TERM")]
for k, v in (svc.get("environment") or {}).items():
    env.append("%s=%s" % (k, v))
proc["env"] = env
cfg["hostname"] = svc.get("hostname", cfg["hostname"])
cfg["root"]["readonly"] = bool(svc.get("read_only", False))

base = os.path.dirname(os.path.abspath(compose))
for v in svc.get("volumes") or []:
    parts = v.split(":")
    src, dst = parts[0], parts[1]
    mode = parts[2] if len(parts) > 2 else "rw"
    cfg["mounts"].append({"destination": dst, "type": "bind", "source": os.path.normpath(os.path.join(base, src)), "options": ["rbind", mode]})

with open(os.path.join(bundle, "config.json"), "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
chmod 755 /var/lib/bench54365253/compose2oci
cd /var/lib/bench54365253/demo
/var/lib/bench54365253/compose2oci docker-compose.yml bundle
sudo runc --root /run/bench54365253 run --bundle bundle bench54365253-demo </dev/null || echo "the container exited with $? (the compose command asks for 7)"
