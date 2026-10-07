# 1. tell the CRI plugin of containerd where its per-registry configuration lives, and describe the registry
#    (plain HTTP) there; the directory has the name of the registry, host:port
sudo mkdir -p "/etc/containerd/certs.d/localhost:32000"
sudo tee "/etc/containerd/certs.d/localhost:32000/hosts.toml" >/dev/null <<'TOML'
server = "http://localhost:32000"

[host."http://localhost:32000"]
  capabilities = ["pull", "resolve"]
TOML
sudo sed -i "/\[plugins.'io.containerd.cri.v1.images'.registry\]/,/^\$/ s|config_path = ''|config_path = '/etc/containerd/certs.d'|" /run/bench69088569/config.toml
# 2. containerd reads config_path at start
sudo /var/lib/bench69088569/bin/containerdctl restart
# 3. the deployment asks for the image by the name it has in the registry
sudo /var/lib/bench69088569/bin/mk8s kubectl set image deployment/argus 'argus=localhost:32000/argus:registry'
sudo /var/lib/bench69088569/bin/mk8s kubectl rollout status deployment/argus --timeout=100s
