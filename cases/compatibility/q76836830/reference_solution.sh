#!/bin/bash
# The front sends a request to the Docker repository connector only when its User-Agent contains "docker" (what Docker's engine sends). containerd's requests carry
# "containerd/<version>", so they went to the web application, which has no /v2/ ("not found"). Add containerd to the rule (the thread's answer adds a second `if` for it),
# check the configuration and reload nginx (a reload keeps the master process).
set -e
W=/tmp/bench76836830
sed -i 's/if (\$http_user_agent ~ docker) {/if ($http_user_agent ~ "docker|containerd") {/' "$W/nginx/nginx.conf"
grep -q 'docker|containerd' "$W/nginx/nginx.conf"
"$W/bin/nginxctl" test
"$W/bin/nginxctl" reload
sleep 1
"$W/bin/pull"
