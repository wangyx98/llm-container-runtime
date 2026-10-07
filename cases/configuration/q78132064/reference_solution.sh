# 1. tell the CRI plugin of containerd where its per-registry configuration lives (containerd reads
#    config_path only when it starts)
sudo python3 - <<'PY'
import re
path = "/run/bench78132064/config.toml"
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
# 2. the directory has the name of the registry being replaced: docker.io is served by the Nexus proxy
sudo mkdir -p /etc/containerd/certs.d/docker.io
sudo tee /etc/containerd/certs.d/docker.io/hosts.toml >/dev/null <<'TOML'
server = "https://registry-1.docker.io"

[host."http://127.0.0.1:8082"]
  capabilities = ["pull", "resolve"]
TOML
sudo /var/lib/bench78132064/bin/containerdctl restart
