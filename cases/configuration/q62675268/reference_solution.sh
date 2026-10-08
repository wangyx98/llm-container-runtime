# 1. kubeadm's --image-repository / imageRepository only decides where kubeadm pulls the control-plane images from.
#    The pod sandbox ("pause") image is pulled by CRI-O itself and is a CRI-O setting: pause_image in crio.conf
#    (table [crio.image]), which still names k8s.gcr.io/pause:3.2. Point it at the private registry.
sudo sed -i 's#^pause_image = .*#pause_image = "registry.bench62675268.test:5000/kubernetes/pause:3.2"#' /run/bench62675268/crio.conf
grep -n '^pause_image' /run/bench62675268/crio.conf
# 2. CRI-O reads its configuration when it starts
sudo /var/lib/bench62675268/bin/crioctl restart
