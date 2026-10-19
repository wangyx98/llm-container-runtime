#!/bin/bash
# Reference solution: ctr cannot publish a port and cannot change the host name of a running container, so the container is made again in the same network namespace with
# --hostname, and the kernel's NAT does what "-p 8080:15672" does: a DNAT rule for the traffic that arrives at the host (PREROUTING: other machines) and for the traffic the host
# makes itself (OUTPUT: the host's own clients), both only for addresses of the host (addrtype LOCAL).
set -e

SOCK=/run/bench72120811/containerd.sock
NETNS=/run/bench72120811/netns/net0

sudo ctr --address "$SOCK" tasks delete --force some-rabbit
sudo ctr --address "$SOCK" containers delete some-rabbit
sudo ctr --address "$SOCK" run -d --with-ns "network:$NETNS" --hostname my-rabbit bench72120811.local/mgmt:1 some-rabbit

IP=$(sudo nsenter --net="$NETNS" hostname -I | awk '{print $1}')
for chain in PREROUTING OUTPUT; do
    sudo iptables -t nat -A "$chain" -p tcp --dport 8080 -m addrtype --dst-type LOCAL -j DNAT --to-destination "$IP:15672"
done
