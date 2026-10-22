#!/bin/bash
# The Secret regcred exists, but the Deployment does not name it: the kubelet sends the credentials of the Secrets that the Pod (or its service account) lists
# under imagePullSecrets, and of no other. The Pod template of blaw gets the list; the Pods are replaced and pull the image with the account.
KUBECTL=/var/lib/bench64935442/bin/kubectl
sudo $KUBECTL patch deployment blaw -n default --type merge -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"regcred"}]}}}}'
sudo $KUBECTL rollout status deployment/blaw -n default --timeout=120s
