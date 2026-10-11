#!/bin/bash
# A CNI plugin that sets nothing up (it is installed as "bench-net" and as "loopback"): containerd creates the network namespace of a pod sandbox
# itself and then asks the CNI plugins to configure it; with this stub every pod gets a network namespace of its own (shared by the containers of
# the pod) without any network in it. ADD answers like a plugin that has made an interface (containerd wants an eth0 with an address in the result;
# the address is made up from the container ID and used nowhere), DEL and CHECK answer nothing, VERSION the versions it speaks.
cat >/dev/null
case "$CNI_COMMAND" in
    ADD)
        ifname="${CNI_IFNAME:-eth0}"
        if [ "$ifname" = eth0 ]; then
            id="${CNI_CONTAINERID:-0000000000}"
            printf '{"cniVersion":"1.0.0","interfaces":[{"name":"eth0","sandbox":"%s"}],"ips":[{"address":"10.255.%d.%d/16","interface":0}]}\n' \
                "$CNI_NETNS" "$((16#${id:0:2}))" "$((16#${id:2:2}))"
        else
            printf '{"cniVersion":"1.0.0","interfaces":[{"name":"%s","sandbox":"%s"}],"ips":[]}\n' "$ifname" "$CNI_NETNS"
        fi ;;
    VERSION) printf '{"cniVersion":"1.0.0","supportedVersions":["0.3.0","0.3.1","0.4.0","1.0.0"]}\n' ;;
    *)       ;;
esac
exit 0
