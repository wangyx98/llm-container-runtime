#!/bin/bash
set -e

BUNDLE=/tmp/bench75716847/bundle
LOG=/tmp/bench75716847/nginx.log

# Root in the container is not all-powerful: runc spec gives the process only CAP_AUDIT_WRITE, CAP_KILL and CAP_NET_BIND_SERVICE, so a root nginx
# can neither chown its cache directories to the user "nginx" (EPERM: the thread's error: no CAP_CHOWN) nor drop its workers to that user (no
# CAP_SETGID / CAP_SETUID). Give the process exactly these three more, in every capability set of config.json, and nothing else (no privileged
# container, no full set), then start the container detached with its output in a file (a detached container that keeps the caller's pipes open
# would keep the caller from returning).
echo "[solution] adding CAP_CHOWN, CAP_SETGID and CAP_SETUID to the capabilities of the process in $BUNDLE/config.json..."
sudo python3 - "$BUNDLE/config.json" <<'PYEOF'
import json
import sys

p = sys.argv[1]
d = json.load(open(p))
for k, caps in d["process"]["capabilities"].items():
    for c in ("CAP_CHOWN", "CAP_SETGID", "CAP_SETUID"):
        if c not in caps:
            caps.append(c)
json.dump(d, open(p, "w"), indent=2)
PYEOF

echo "[solution] starting the container bench75716847 detached..."
sudo runc run -d --bundle "$BUNDLE" --pid-file /tmp/bench75716847/nginx.pid bench75716847 </dev/null >"$LOG" 2>&1

for _ in $(seq 1 20); do
    [ "$(sudo runc state bench75716847 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)" = running ] && break
    sleep 0.5
done
sudo runc ps bench75716847
sudo runc state bench75716847 | grep '"status"'
cat "$LOG"
