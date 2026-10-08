# 1. the usual place for per-registry TLS settings is the registry hosts directory of the CRI (config_path); the
#    legacy configs.<host>.tls table is not honoured any more. The directory is named after the registry (host:port).
sudo mkdir -p /var/lib/bench73415766/certs.d/pvt-a.registry.test:5028
sudo tee /var/lib/bench73415766/certs.d/pvt-a.registry.test:5028/hosts.toml >/dev/null <<'TOML'
server = "https://pvt-a.registry.test:5028"

[host."https://pvt-a.registry.test:5028"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
TOML
# 2. tell the CRI plugin where that directory is (containerd reads config_path only when it starts)
sudo python3 - <<'PY'
import re
path = "/run/bench73415766/config.toml"
out, section = [], ""
for line in open(path):
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    if section.endswith(".registry") and "cri" in section and re.match(r"^\s*config_path\s*=", line):
        line = re.sub(r"=.*", "= '/var/lib/bench73415766/certs.d'", line) + "\n"
    out.append(line)
open(path, "w").writelines(out)
PY
sudo /var/lib/bench73415766/bin/containerdctl restart
for i in $(seq 1 30); do sudo ctr -a /run/bench73415766/containerd.sock version >/dev/null 2>&1 && break; sleep 1; done
SOCK=unix:///run/bench73415766/containerd.sock
sudo crictl --runtime-endpoint "$SOCK" --image-endpoint "$SOCK" pull pvt-a.registry.test:5028/team/app:1.0
sudo ctr -a /run/bench73415766/containerd.sock -n k8s.io run --rm pvt-a.registry.test:5028/team/app:1.0 bench73415766-check /app hello </dev/null
