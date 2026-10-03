#!/bin/bash
set -e

# `crictl rmi --prune` removes the images that no container uses, but an
# exited container still counts as a user of its image. So, like
# `docker system prune -a`, remove the stopped containers first and the
# images they leave unused after that; a running container and the image it
# runs stay.

echo "[solution] stopped containers before:"
sudo crictl ps -a --state exited

echo "[solution] removing the stopped containers..."
EXITED=$(sudo crictl ps -a -q --state exited)
if [ -n "$EXITED" ]; then
    # shellcheck disable=SC2086
    sudo crictl rm $EXITED
fi

echo "[solution] removing the images no container uses any more..."
sudo crictl rmi --prune

echo "[solution] containers and images now:"
sudo crictl ps -a
sudo crictl images
