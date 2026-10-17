# 1. The containers get the core limit of the containerd process (containerd puts no RLIMIT_CORE in the OCI spec of a container; the main process and every exec inherit it),
#    and the unit file of containerd has LimitCORE=infinity. A drop-in sets soft and hard to 0.
sudo mkdir -p /etc/systemd/system/bench72094271-containerd.service.d
printf '[Service]\nLimitCORE=0\n' | sudo tee /etc/systemd/system/bench72094271-containerd.service.d/10-core.conf >/dev/null
# 2. systemd reads unit files and drop-ins at daemon-reload, so reload first, then restart
sudo systemctl daemon-reload
sudo systemctl restart bench72094271-containerd.service
