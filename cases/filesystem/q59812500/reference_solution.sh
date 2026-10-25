#!/bin/bash
# The reference: the working directory of the command is set inside the new root (cmd.Dir = "/", which Go applies right after the chroot); rebuilt with the lab's Go.
set -e
D=/var/lib/bench59812500/daemon
python3 - "$D/main.go" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\t\tChroot:     rootfs,\n\t}\n"
assert s.count(old) == 1
open(p, "w").write(s.replace(old, old + '\tcmd.Dir = "/"\n'))
PY
cd "$D" && /var/lib/bench59812500/go/bin/go build -o daemon .
