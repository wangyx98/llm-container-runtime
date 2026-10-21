#!/bin/bash
# Reference solution of q53435138: the pod gets a dockerd of its own, the DinD container next to the agent: privileged, its /var/lib/docker an emptyDir, the docker socket
# in an emptyDir that both containers share; nothing of the node is mounted (no socket). The kubelet replaces the static pod when its manifest changes.
set -e
L=/var/lib/bench53435138
R=/run/bench53435138
sudo tee "$L/kubelet/manifests/jenkins.yaml" >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: jenkins
  namespace: ci
spec:
  hostNetwork: true
  containers:
  - name: agent
    image: bench53435138.local/agent:1
    imagePullPolicy: Never
    volumeMounts:
    - {name: docker-run, mountPath: /var/run}
    - {name: workspace, mountPath: /home/jenkins/agent}
  - name: dind
    image: bench53435138.local/dind:1
    imagePullPolicy: Never
    securityContext: {privileged: true}
    volumeMounts:
    - {name: docker-run, mountPath: /var/run}
    - {name: docker-lib, mountPath: /var/lib/docker}
  volumes:
  - {name: docker-run, emptyDir: {}}
  - {name: docker-lib, emptyDir: {}}
  - name: workspace
    hostPath: {path: $L/workspace, type: Directory}
EOF
CRI="sudo crictl -r unix://$R/containerd.sock -i unix://$R/containerd.sock"
for _ in $(seq 90); do
    A=$($CRI ps -q --name agent --state running 2>/dev/null | head -1)
    [ -n "$A" ] && $CRI exec "$A" docker version >/dev/null 2>&1 && break
    sleep 2
done
$CRI exec "$A" docker version --format 'client {{.Client.Version}}, server {{.Server.Version}}'
