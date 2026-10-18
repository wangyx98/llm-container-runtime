#!/bin/bash
set -e
# Reference solution. A privileged Pod shares the host's kernel, not its file system, but everything that `nerdctl run -d` hands to containerd is
# a PATH that containerd, runc or the log process then open ON THE HOST. Each of them has to exist on both sides under the same name:
#   1. containerd's root: the client mounts the image's snapshot (the "failed to mount ... snapshots/N/fs" error)
#   2. the CNI plugin directory and 3. the CNI network configuration (nerdctl checks them in the Pod, the host side runs the plugins)
#   4. nerdctl's data root /var/lib/nerdctl (hosts, resolv.conf and the log of every container)
#   5. the nerdctl binary: containerd starts it, by the path the Pod's nerdctl has, as log process and as OCI hook; the host's own copy is
#      mounted and put first in PATH (the Pod's brew path does not exist on the host)
#   6. the containerd socket: the log process connects to the address that is stored with the container, so the Pod must use an address
#      that is valid on the host too (CONTAINERD_ADDRESS; nerdctl hands its environment to the hook)
# The volumes of a Pod cannot be changed: the Pod is deleted and created again from the edited manifest.
sudo tee /var/lib/bench75845783/nerdctl-pod.yaml >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: nerdctl-pod
  name: nerdctl-pod
spec:
  containers:
    - name: nerdctl
      image: bench75845783.local/nerdctl-pod:1
      imagePullPolicy: IfNotPresent
      env:
        - name: CNI_PATH
          value: /var/lib/bench75845783/cni/bin
        - name: NETCONFPATH
          value: /var/lib/bench75845783/cni/net.d
        - name: PATH
          value: /var/lib/bench75845783/libexec:/home/linuxbrew/.linuxbrew/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        - name: CONTAINERD_ADDRESS
          value: /run/bench75845783/containerd.sock
      securityContext:
        privileged: true
        runAsUser: 0
      volumeMounts:
        - mountPath: /var/run/containerd
          name: containerd-dir
        - mountPath: /var/run/containerd/containerd.sock
          name: containerd
        - mountPath: /run/bench75845783/containerd.sock
          name: containerd
        - mountPath: /var/lib/bench75845783/containerd
          name: containerd-root
        - mountPath: /var/lib/nerdctl
          name: nerdctl-data
        - mountPath: /var/lib/bench75845783/cni
          name: cni
          readOnly: true
        - mountPath: /var/lib/bench75845783/libexec
          name: libexec
          readOnly: true
  restartPolicy: Always
  volumes:
    - name: containerd
      hostPath:
        path: /run/bench75845783/containerd.sock
    - name: containerd-dir
      hostPath:
        path: /var/run/containerd
    - name: containerd-root
      hostPath:
        path: /var/lib/bench75845783/containerd
    - name: nerdctl-data
      hostPath:
        path: /var/lib/nerdctl
        type: DirectoryOrCreate
    - name: cni
      hostPath:
        path: /var/lib/bench75845783/cni
    - name: libexec
      hostPath:
        path: /var/lib/bench75845783/libexec
EOF
sudo /var/lib/bench75845783/bin/kubectl delete pod nerdctl-pod --wait
sudo /var/lib/bench75845783/bin/kubectl apply -f /var/lib/bench75845783/nerdctl-pod.yaml
sudo /var/lib/bench75845783/bin/kubectl wait --for=condition=Ready pod/nerdctl-pod --timeout=120s
