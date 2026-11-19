#!/bin/bash
# The warning comes from the application's own call: fs.copyFileSync makes node ask the kernel for copy_file_range, which the sandbox does not implement (it reports the call and node
# falls back to read/write, so the copy works). There is no switch to silence the report: the application must not make the call. Copy by reading and writing, then start the service again.
set -e
sed -i 's|^function copy(src, dst) {.*|function copy(src, dst) { fs.writeFileSync(dst, fs.readFileSync(src)); }|' /tmp/bench57214133/app/server.js
/tmp/bench57214133/bin/svc start
/tmp/bench57214133/bin/svc client GET / gzip
