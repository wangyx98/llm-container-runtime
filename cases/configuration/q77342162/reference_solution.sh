# The legacy "mirrors" endpoint is not a base URL to which containerd adds /v2: a path in it replaces /v2, so
# https://harbor/kubernetes-cache makes containerd ask for /kubernetes-cache/<repo>/manifests/... (404), and the host alone
# gives /v2/<repo>/manifests/... without the project (Harbor: 400). Harbor names the repository <project>/<repo>, so the
# requests must go to /v2/kubernetes-cache/<repo>/...: a hosts.toml whose host has that path, with override_path = true
# (containerd then uses the path as it is, without adding /v2). The legacy mirrors table and config_path exclude each other.
sudo python3 - <<'PY'
import re
path = "/run/bench77342162/config.toml"
text = open(path).read()
text = re.sub(r"\n# the mirror of the question.*\Z", "\n", text, flags=re.S)
out, section = [], ""
for line in text.splitlines(True):
    m = re.match(r"^\s*\[+\s*([^\]]+?)\s*\]+\s*$", line)
    if m:
        section = m.group(1).strip("'\"")
    if section.endswith(".registry") and "cri" in section and re.match(r"^\s*config_path\s*=", line):
        line = re.sub(r"=.*", "= '/etc/containerd/certs.d'", line) + "\n"
    out.append(line)
open(path, "w").writelines(out)
PY
sudo mkdir -p /etc/containerd/certs.d/registry.k8s.io
sudo tee /etc/containerd/certs.d/registry.k8s.io/hosts.toml >/dev/null <<'TOML'
server = "https://registry.k8s.io"

[host."http://harbor.bench77342162.test:8083/v2/kubernetes-cache"]
  capabilities = ["pull", "resolve"]
  override_path = true
TOML
sudo /var/lib/bench77342162/bin/containerdctl restart
