#!/bin/bash
set -e
W=/tmp/bench76666855
# The load generator's process hangs below a containerd-shim: the shim's command line names the namespace (moby) and the id of the container it keeps; that container's
# restart policy (always) is what brings the process back whenever the services start, so the policy has to go before the container is stopped and removed.
PID=$(pgrep -f '^/jmeter/bin/run-lp-endpoint-tests .*jmeter-lp-endpoints' | head -1)
SHIM=$(awk '{print $4}' /proc/$PID/stat)
ID=$(tr '\0' ' ' < /proc/$SHIM/cmdline | sed -n 's/.* -id \([0-9a-f]\{64\}\) .*/\1/p')
echo "process $PID, shim $SHIM, container $ID"
$W/bin/docker inspect -f '{{.Name}} policy={{.HostConfig.RestartPolicy.Name}}' "$ID"
$W/bin/docker update --restart no "$ID"
$W/bin/docker stop "$ID"
$W/bin/docker rm "$ID"
