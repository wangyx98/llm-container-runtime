echo 'container-runtime-endpoint: unix:///run/bench71572715/containerd.sock' | sudo tee -a /etc/rancher/k3s/config.yaml
sudo /var/lib/bench71572715/bin/k3sctl restart
