#!/bin/bash
set -e

CASE_ID="bench70710123"
IMAGE="docker.io/library/$CASE_ID:latest"

# nerdctl does not define host.docker.internal by itself (Docker Desktop does). The Docker-
# compatible way to define it is --add-host with the special value host-gateway, which nerdctl
# turns into the IP address of the host. The host service listens on all interfaces, so the
# container can reach it on that address.
echo "[solution] starting the application container with host.docker.internal -> host-gateway..."
sudo nerdctl run -d --name "$CASE_ID" \
    --add-host host.docker.internal:host-gateway \
    "$IMAGE" </dev/null

echo "[solution] done. The application's log:"
sleep 3
sudo nerdctl logs "$CASE_ID" 2>&1 | tail -n 5 || true
