# k3s writes the configuration of its embedded containerd itself, at every start (config.toml and the hosts directory
# certs.d below /var/lib/rancher/k3s/agent/etc/containerd), so hand edits of the generated files, and /etc/containerd,
# are not the place. The supported way is /etc/rancher/k3s/registries.yaml: the CA certificate for that registry only
# (certificate verification stays on); k3s renders it into containerd's hosts.toml when it starts.
sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<'EOF'
configs:
  "registry.bench75817724.test:5000":
    tls:
      ca_file: /var/lib/bench75817724/pki/ca.crt
EOF
sudo /var/lib/bench75817724/bin/k3sctl restart
