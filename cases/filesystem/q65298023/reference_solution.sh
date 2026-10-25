#!/bin/bash
# Reference: the first run left the container sql1 (stopped) and its failure is not about MySQL: `ctr run` builds the container from containerd's default OCI spec, which puts an empty root-owned tmpfs on /run
# (the image's /var/run is a symlink to /run), so the image's /run/mysqld, owned by mysql, is hidden and the server (user mysql, uid 999 in the image) cannot make its lock files and sockets. Give /run/mysqld
# a mount of its own that mysql owns: a host directory made for uid/gid 999 (the container's numbers, not the host's mysql user), mode 0750; then run the container again, as before.
set -e
L=/var/lib/bench65298023
CTR=$L/bin/ctr
sudo $CTR tasks rm sql1 2>/dev/null || true
sudo $CTR containers rm sql1
sudo install -d -m 750 -o 999 -g 999 $L/mysqld-run
sudo $CTR run -d --log-uri file:///run/bench65298023/sql1.log --mount type=bind,src=$L/context,dst=/context,options=rbind:ro \
    --mount type=bind,src=$L/mysqld-run,dst=/run/mysqld,options=rbind:rw --env MYSQL_ROOT_PASSWORD=test123 bench65298023.local/mysql:8.0.22 sql1
