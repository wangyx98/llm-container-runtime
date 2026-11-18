#!/bin/bash
# The warning comes from the service itself: it sends SO_PRIORITY (here, with its default value 0, like the thread's Undertow sends SO_OOBINLINE=false) and the sandbox
# logs the call as unsupported. There is no switch to silence it: the call must not be made. Remove the option from the config and start the service again.
set -e
sed -i '/^[[:space:]]*so_priority/d' /tmp/bench58370120/conf/server.conf
/tmp/bench58370120/bin/svc start
/tmp/bench58370120/bin/svc exec /client
