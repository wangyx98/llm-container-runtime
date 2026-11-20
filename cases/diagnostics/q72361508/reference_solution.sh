#!/bin/bash
set -e

CONF=/var/lib/bench72361508/etc/containerd.toml

echo "[solution] the level of containerd's own log is [debug] level in its configuration: info -> warn (warnings and errors stay)"
sudo sed -i 's/^\([[:space:]]*level = \)"info"/\1"warn"/' "$CONF"
grep -n -A1 '^\[debug\]' "$CONF"
sudo /tmp/bench72361508/bin/node-ctl restart
