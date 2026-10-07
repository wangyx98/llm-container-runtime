SOCK=/run/bench64513122/containerd.sock
SRC=docker.io/vendor64513122/app:2.2.2
TARGET=127.0.0.1:15064/bench64513122-org/vendor64513122/app:2.2.2
sudo ctr -a $SOCK -n default images tag $SRC $TARGET
sudo ctr -a $SOCK -n default images push --plain-http $TARGET
sudo ctr -a $SOCK -n k8s.io images pull --plain-http $TARGET
