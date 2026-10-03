#!/bin/bash
set -e

# The docker-archive carries no image name (RepoTags is empty in its
# manifest.json), so a plain import creates no image record at all: it
# succeeds, but there is nothing for 'ctr images ls' to list. Give the import a
# name for the image with --index-name.
sudo ctr -n bench75385049 images import \
    --index-name docker.io/library/bench75385049-hello:latest \
    /tmp/bench75385049/hello.tar
