# 1. the CRI reads per-registry settings from a hosts directory (config_path); containerd reads config_path only when
#    it starts. The directory is named after the registry, host:port.
sudo python3 - <<'PY'
import re
path = "/run/bench72419513/config.toml"
out, section = [], ""
for line in open(path):
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    if section.endswith(".registry") and "cri" in section and re.match(r"^\s*config_path\s*=", line):
        line = re.sub(r"=.*", "= '/etc/containerd/certs.d'", line) + "\n"
    out.append(line)
open(path, "w").writelines(out)
PY
sudo mkdir -p "/etc/containerd/certs.d/registry.bench72419513.test:5000"
sudo tee "/etc/containerd/certs.d/registry.bench72419513.test:5000/hosts.toml" >/dev/null <<'TOML'
server = "http://registry.bench72419513.test:5000"

[host."http://registry.bench72419513.test:5000"]
  capabilities = ["pull", "resolve"]
TOML
sudo /var/lib/bench72419513/bin/containerdctl restart
for i in $(seq 1 30); do sudo ctr -a /run/bench72419513/containerd.sock version >/dev/null 2>&1 && break; sleep 1; done
SOCK=unix:///run/bench72419513/containerd.sock
sudo crictl --runtime-endpoint "$SOCK" --image-endpoint "$SOCK" pull registry.bench72419513.test:5000/team/imagename:v1
