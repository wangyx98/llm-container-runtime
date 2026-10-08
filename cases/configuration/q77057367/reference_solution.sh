# ctr does not expand a short name to Docker Hub (or to any default registry): the first part of the name is
# taken as the registry host. Name the registry of the image explicitly; it speaks plain HTTP.
CTR="sudo ctr -a /run/bench77057367/containerd.sock"
$CTR images pull --plain-http 127.0.0.1:18077/e2eteam/busybox:1.29
$CTR run --rm 127.0.0.1:18077/e2eteam/busybox:1.29 bench77057367-check /app hello
