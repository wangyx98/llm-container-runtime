# 1. containerd.toml is not kept: mk8s-run-containerd makes it again from containerd-template.toml at every start, so the registry entry goes into the template
#    (the plugin of the CRI image service in a containerd 2.x configuration; the endpoint is plain http)
sudo tee -a /var/lib/bench66642654/current/args/containerd-template.toml >/dev/null <<'TOML'

[plugins.'io.containerd.cri.v1.images'.registry.mirrors.'10.66.64.45:32000']
  endpoint = ['http://10.66.64.45:32000']
TOML
# 2. the configuration is read when containerd starts
sudo /var/lib/bench66642654/bin/mk8sctl restart
