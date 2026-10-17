#!/bin/bash
# The build containers of BuildKit take their name servers from the [dns] section of buildkitd.toml (the old resolver), while the containers of "nerdctl run" take theirs from nerdctl.toml (the
# corporate name server). Give BuildKit the corporate name server and restart it.
set -e
ETC=/etc/bench70704948
NS=$(sudo sed -n -E 's/^dns *= *\["([^"]+)".*/\1/p' "$ETC/nerdctl.toml")
sudo sed -i -E "s/^( *nameservers *= *).*/\1[\"$NS\"]/" "$ETC/buildkitd.toml"
sudo /var/lib/bench70704948/bin/buildkitctl restart
