sudo tee /etc/bench73394153/provision.d/10-corporate-proxy.sh >/dev/null <<'EOF2'
#!/bin/bash
set -e
CRED=/etc/bench73394153/proxy-credentials
enc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
PROXY="http://$(enc "$(sed -n 1p "$CRED")"):$(enc "$(sed -n 2p "$CRED")")@127.0.0.1:33942"
NO_PROXY="localhost,127.0.0.1,$(hostname -I | xargs | tr ' ' ',')"
for f in /etc/bench73394153/conf.d/k3s /etc/bench73394153/profile; do
    printf "export HTTPS_PROXY='%s'\nexport HTTP_PROXY='%s'\nexport NO_PROXY='%s'\n" "$PROXY" "$PROXY" "$NO_PROXY" >> "$f"
done
EOF2
sudo chmod 755 /etc/bench73394153/provision.d/10-corporate-proxy.sh
sudo /var/lib/bench73394153/bin/rdrestart
