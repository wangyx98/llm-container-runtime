#!/bin/bash
# Reference solution: the node's containerd dies in the metadata plugin (metadata.(*DB).Init) on a torn page of meta.db, and the page is the root of the NEWEST transaction. bbolt keeps two meta pages and
# writes every transaction copy-on-write, so the transaction before the last one is complete in the same file: if the newer meta page is not valid (magic or checksum - a checksum of 0 means "no checksum" and
# is accepted), bbolt opens the older one. Only the last transaction is lost. The broken file is kept first, byte for byte, as evidence.
set -e
LIB="/var/lib/bench67889258"
DB="$LIB/containerd/io.containerd.metadata.v1.bolt/meta.db"
sudo "$LIB/bin/nodectl" start 2>&1 | tail -2 || true
sudo cp -p "$DB" "$LIB/evidence/meta.db.corrupt"
sudo python3 - "$DB" <<'PYEOF'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
PS = 4096
txid = [struct.unpack("<Q", d[i * PS + 16 + 48:i * PS + 16 + 56])[0] for i in (0, 1)]
new = 0 if txid[0] > txid[1] else 1
print("meta pages: txid %d / %d -> invalidating meta %d (txid %d)" % (txid[0], txid[1], new, txid[new]))
struct.pack_into("<Q", d, new * PS + 16 + 56, 1)      # a checksum that is wrong and not 0
open(p, "wb").write(d)
PYEOF
sudo "$LIB/bin/nodectl" start
sudo "$LIB/bin/ctr" images ls
sudo "$LIB/bin/ctr" containers ls
