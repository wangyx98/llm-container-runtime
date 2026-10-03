#!/bin/bash
set -o pipefail

IMG="docker.io/library/bench74595501-app:latest"

# Namespaces keep their own image records, so the image has to be created in
# k8s.io. Streaming the export of the default-namespace image straight into
# an import in k8s.io does that without writing an archive to disk. An export
# can abort midway on this node ("error copying stream ... file already
# closed"), so check that the image really arrived, and repeat if not.
for attempt in 1 2 3 4 5; do
    echo "[solution] attempt $attempt: export from default | import into k8s.io"
    if sudo ctr -n default images export /dev/stdout "$IMG" | sudo ctr -n k8s.io images import - \
       && sudo ctr -n k8s.io images ls -q | grep -qxF "$IMG"; then
        echo "[solution] $IMG is in k8s.io"
        exit 0
    fi
    sleep 1
done
echo "[solution] the image did not arrive in k8s.io"
exit 1
