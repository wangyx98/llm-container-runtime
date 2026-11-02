#!/bin/bash
set -e

W=/tmp/bench77579349
N="sudo $W/bin/nerdctl"
cd $W/compose

echo "[solution] Traefik v3 has no containerd provider (the flag --providers.containerd... is rejected at start-up: the"
echo "[solution] container exits at once), and the containerd socket is not a Docker API. Declare the route in a file instead:"
mkdir -p dynamic
cat > dynamic/apache.yml <<'YEOF'
http:
  routers:
    apache:
      rule: Host(`example.com`)
      entryPoints: [web]
      service: apache
  services:
    apache:
      loadBalancer:
        servers:
          - url: http://apache:80
YEOF
cat > docker-compose.yaml <<'YEOF'
version: "3"

services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    volumes:
      - ./dynamic:/etc/traefik/dynamic:ro
    command:
      - "--api.insecure=true"
      - "--log.level=DEBUG"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web-secure.address=:443"
    ports:
      - "80:80"
      - "443:443"

  apache:
    image: httpd:latest
    container_name: apache
YEOF
$N compose up -d
sleep 2
