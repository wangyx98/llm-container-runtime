#!/bin/bash
set -e
# Reference solution. `nerdctl build` does not build anything itself: it runs the program buildctl, which talks to a BuildKit daemon, and the
# daemon (here buildkitd with a containerd worker) does the build and stores the result in containerd. Three things are missing in the Pod:
#   1. the program buildctl (nerdctl looks it up in PATH): the machine's own copy is mounted into the Pod
#   2. a way to reach buildkitd: nerdctl tries unix:///run/buildkit-default/buildkitd.sock and unix:///run/buildkit/buildkitd.sock, so the
#      socket directory of buildkitd is mounted at /run/buildkit (the build context travels over this connection; no path has to be shared)
#   3. the containerd worker works in the namespace "buildkit", but the base image of the Dockerfile and the images of the node are in
#      "default": the worker must use "default" (change the namespace in buildkitd.toml, restart buildkitd)
# The volumes of a Pod cannot be changed: the Pod is deleted and created again from the edited manifest. It stays unprivileged and root.
L=/var/lib/bench70231694
KC="sudo $L/bin/kubectl"
sudo sed -i 's/^\([[:space:]]*namespace = \).*/\1"default"/' $L/buildkit/buildkitd.toml
sudo $L/bin/buildkitctl restart
for _ in $(seq 1 30); do
    sudo $L/libexec/buildctl --addr unix:///run/bench70231694/buildkit/buildkitd.sock debug workers >/dev/null 2>&1 && break
    sleep 1
done
sudo tee $L/builder.yaml >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: builder
  name: builder
spec:
  containers:
    - name: nerdctl
      image: bench70231694.local/builder:1
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: false
        runAsUser: 0
      volumeMounts:
        - mountPath: /workspace
          name: workspace
          readOnly: true
        - mountPath: /run/containerd/containerd.sock
          name: containerd
        - mountPath: /run/buildkit
          name: buildkit
        - mountPath: /usr/local/bin/buildctl
          name: buildctl
  restartPolicy: Always
  volumes:
    - name: workspace
      hostPath:
        path: /var/lib/bench70231694/workspace
    - name: containerd
      hostPath:
        path: /run/bench70231694/containerd.sock
    - name: buildkit
      hostPath:
        path: /run/bench70231694/buildkit
    - name: buildctl
      hostPath:
        path: /var/lib/bench70231694/libexec/buildctl
EOF
$KC delete pod builder --wait >/dev/null
$KC apply -f $L/builder.yaml >/dev/null
$KC wait --for=condition=Ready pod/builder --timeout=120s >/dev/null
$KC exec builder -- nerdctl build -t bench70231694.local/payload:1 /workspace
$KC exec builder -- nerdctl images
