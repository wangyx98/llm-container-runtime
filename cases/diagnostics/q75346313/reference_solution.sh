#!/bin/bash
set -e

WORK_DIR="/tmp/bench75346313"
DSOCK="/run/bench75346313/docker.sock"

# dockerd loads its default AppArmor profile, docker-default, when it starts and finds it not loaded in the kernel. It does that with the
# apparmor_parser it finds on its PATH, and the PATH of this daemon is the lab's tools directory, which has no such tool: that is the whole
# failure. The parser is installed on this VM; restoring the dependency is making it available where the daemon looks for it. Nothing about
# the profile or the container changes: the daemon loads docker-default itself, and the container is confined by the default.
PARSER=$(PATH="$PATH:/usr/sbin:/sbin" command -v apparmor_parser)
ln -sf "$PARSER" "$WORK_DIR/tools/apparmor_parser"
bash "$WORK_DIR/start-docker.sh"

docker -H "unix://$DSOCK" load -i "$WORK_DIR/app.tar"
docker -H "unix://$DSOCK" run -d --name bench75346313-web bench/app:1

echo "[solution] the container, and the label of its process:"
docker -H "unix://$DSOCK" ps --filter name=bench75346313-web --format '{{.Names}} {{.Status}}'
sudo cat "/proc/$(docker -H "unix://$DSOCK" inspect -f "{{.State.Pid}}" bench75346313-web)/attr/current" | tr -d "\0"; echo
