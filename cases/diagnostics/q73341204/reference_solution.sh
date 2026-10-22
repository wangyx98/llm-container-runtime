#!/bin/bash
# runc and ctr of the getty look at the node's DEFAULT places: runc's default root (only the onboot containers, started by runc itself) and containerd's namespace "default" (empty).
# LinuxKit starts its services through containerd, in the namespace services.linuxkit, with a runc root of their own. The container is found there and entered with `ctr task exec`.
B=/var/lib/bench73341204/bin
A=/tmp/bench73341204/answer
NS=services.linuxkit
sudo $B/ctr namespaces ls
sudo $B/ctr -n $NS containers ls
echo "$NS redis" > $A/container.txt
sudo $B/ctr -n $NS tasks exec --exec-id cfg redis sha256sum /etc/redis.conf | awk '{print $1}' > $A/config.sha256
sudo $B/ctr -n $NS tasks exec --exec-id ping redis redis-cli ping > $A/ping.txt
