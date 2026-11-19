#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

CASE_ID="bench57214133"
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_BASE="/run/$CASE_ID"                 # runsc's state root
LIB_BASE="/var/lib/$CASE_ID"             # runsc, node, runsc's debug logs
CACHE="/var/cache/$CASE_ID"              # pinned downloads (kept by cleanup, sha512 checked at every setup)
WORK_DIR="/tmp/$CASE_ID"                 # what the job has: the app, the wrapper, the bundle
APP="$WORK_DIR/app"
BUNDLE="$WORK_DIR/bundle"
STATE_DIR="$WORK_DIR/.bench"             # root-only record of what is true
CID="$CASE_ID"
RUNSC_V="20260105.0"
NODE_V="22.23.4"

case "$(uname -m)" in
    x86_64|amd64)  A="x86_64"  SHA="15c8adabc9f1006d469177b0ec3962d4993e01c85be17d381a4979029eacc7db37ef354e3eafd279573135a1adf81baffc5c19f2bbfac932c79386f6ac74e52f"
                   NA="x64"    NSHA="062ed594fe0b350072e96e34b6fa9f5ca3cc193f6d9ebb3ba726e2a31ef2a9031288c6a02ae672c8821bfe960cd9d6ed3e55f24272e27f466d83250822641091" ;;
    aarch64|arm64) A="aarch64" SHA="cc98ad73e8d181f4738c97883180bc76cf8b2eb773c11f3a44f1636d0b0e00f2ee9228e4eecd414f94d6410f4877e6c93260b8070130fba767583026115d1038"
                   NA="arm64"  NSHA="ce54f866020e2bd95b550c780bcc7e6825c3e6b8e526ba4c801cfd8829315d411afb66f95875d8fdb02e540468b89a031529ede7aac702dbff243826c9027a5c" ;;
    *) echo "[setup] NOT APPLICABLE: $(uname -m) (runsc and node are pinned for x86_64 and aarch64)"; exit 1 ;;
esac
URL="https://storage.googleapis.com/gvisor/releases/release/$RUNSC_V/$A/runsc"
NURL="https://registry.npmjs.org/node-linux-$NA/-/node-linux-$NA-$NODE_V.tgz"

echo "[setup] checking what the case needs (gVisor's runsc $RUNSC_V is the sandbox under test, Node $NODE_V is the application's runtime; both pinned by sha512)..."
for c in python3 curl sudo sha512sum tar; do command -v "$c" >/dev/null || { echo "[setup] ERROR: $c not found"; exit 1; }; done
[ -d /usr/lib ] || { echo "[setup] ERROR: no /usr/lib on the host"; exit 1; }

echo "[setup] clearing leftovers from a previous run (idempotency)..."
bash "$CASE_DIR/cleanup.sh" >/dev/null 2>&1 || true

fetch() {   # fetch NAME URL SHA512 : the file is in $CACHE/NAME afterwards, with the pinned sha512
    local name=$1 url=$2 sha=$3 tmp
    if sudo test -f "$CACHE/$name" && echo "$sha  $CACHE/$name" | sudo sha512sum -c --quiet - 2>/dev/null; then return 0; fi
    for try in 1 2 3; do
        tmp=$(mktemp)
        if curl -fsSL --max-time 300 -o "$tmp" "$url" && echo "$sha  $tmp" | sha512sum -c --quiet - 2>/dev/null; then sudo install -m 0644 "$tmp" "$CACHE/$name"; rm -f "$tmp"; return 0; fi
        rm -f "$tmp"; sleep 3
    done
    return 1
}
echo "[setup] runsc $RUNSC_V ($A) and node $NODE_V ($NA): from $CACHE, else downloaded; the sha512 is checked either way..."
sudo install -d -m 0755 "$CACHE"
fetch "runsc-$A" "$URL" "$SHA" || { echo "[setup] ERROR: could not download runsc with the pinned sha512"; exit 1; }
fetch "node-$NODE_V-$NA.tgz" "$NURL" "$NSHA" || { echo "[setup] ERROR: could not download node with the pinned sha512"; exit 1; }

echo "[setup] resetting the case directories..."
sudo rm -rf "$WORK_DIR" "$LIB_BASE" "$RUN_BASE"
sudo install -d -m 0755 "$LIB_BASE" "$LIB_BASE/bin" "$LIB_BASE/logs" "$LIB_BASE/node/bin" "$RUN_BASE"
sudo install -m 0755 "$CACHE/runsc-$A" "$LIB_BASE/bin/runsc"
X=$(mktemp -d)
trap 'rm -rf "$X"' EXIT
tar -xzf "$CACHE/node-$NODE_V-$NA.tgz" -C "$X" package/bin/node
sudo install -m 0755 "$X/package/bin/node" "$LIB_BASE/node/bin/node"
mkdir -p "$APP/public" "$WORK_DIR/tools" "$WORK_DIR/bin" "$WORK_DIR/data" "$BUNDLE/rootfs"
sudo install -d -m 0700 "$STATE_DIR"
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')

echo "[setup] the site: three assets, each as a plain file and as a pre-compressed .gz (the thread's app served such files with express-static-gzip), made for this run (the nonce is in the HTML)..."
python3 - "$APP/public" "$NONCE" <<'PYEOF'
import gzip, sys
d, nonce = sys.argv[1:3]
lorem = "The quick brown fox jumps over the lazy dog while the sandbox keeps a log of every call it does not implement. "
files = {
  "index.html": "<!doctype html>\n<html><head><title>site</title><link rel=stylesheet href=/style.css></head><body>\n<!-- nonce=%s -->\n%s\n<script src=/app.js></script></body></html>\n" % (nonce, "".join("<p>%d %s</p>\n" % (i, lorem) for i in range(60))),
  "app.js": "// nonce=%s\n%s" % (nonce, "".join("function f%d(x) { return x * %d + %d; }\n" % (i, i, i * 7) for i in range(200))),
  "style.css": "/* nonce=%s */\n%s" % (nonce, "".join(".c%d { margin: %dpx; padding: %dpx; color: #%06x; }\n" % (i, i, i % 9, i * 4099 % 0xffffff) for i in range(120))),
}
for name, text in files.items():
    raw = text.encode()
    open("%s/%s" % (d, name), "wb").write(raw)
    open("%s/%s.gz" % (d, name), "wb").write(gzip.compress(raw, 9, mtime=0))
PYEOF

echo "[setup] the application $APP/server.js (Node, no packages): at start it publishes the files of public/ into /data/www by copying them with fs.copyFileSync, POST /refresh does it again, GET serves from /data/www (the .gz when the client accepts gzip)..."
cat > "$APP/server.js" <<'JEOF'
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');

const SRC = '/app/public';          // the files of the image (read-only)
const DST = '/data/www';            // the directory the server serves from
const NONCE = process.env.NONCE || 'unknown';
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.css': 'text/css' };
let publishes = 0;

function copy(src, dst) { fs.copyFileSync(src, dst); }

function publish() {
  fs.mkdirSync(DST, { recursive: true });
  for (const name of fs.readdirSync(SRC)) copy(path.join(SRC, name), path.join(DST, name));
  publishes++;
}

function serve(req, res) {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname === '/status') {
    res.writeHead(200, { 'Content-Type': 'text/plain', 'X-Nonce': NONCE });
    return res.end('nonce=' + NONCE + '\npublishes=' + publishes + '\nfiles=' + fs.readdirSync(DST).sort().join(',') + '\n');
  }
  if (url.pathname === '/refresh' && req.method === 'POST') {
    publish();
    res.writeHead(200, { 'Content-Type': 'text/plain', 'X-Nonce': NONCE });
    return res.end('refreshed publishes=' + publishes + '\n');
  }
  const name = path.posix.normalize(url.pathname === '/' ? '/index.html' : url.pathname);
  if (req.method !== 'GET' || name.includes('..') || !TYPES[path.extname(name)]) { res.writeHead(404, { 'X-Nonce': NONCE }); return res.end('not found\n'); }
  const plain = path.join(DST, name), gz = plain + '.gz';
  const headers = { 'Content-Type': TYPES[path.extname(name)], 'Vary': 'Accept-Encoding', 'X-Nonce': NONCE };
  let file = plain;
  if (/\bgzip\b/.test(req.headers['accept-encoding'] || '') && fs.existsSync(gz)) { file = gz; headers['Content-Encoding'] = 'gzip'; }
  fs.readFile(file, (err, body) => {
    if (err) { res.writeHead(404, { 'X-Nonce': NONCE }); return res.end('not found\n'); }
    res.writeHead(200, headers);
    res.end(body);
  });
}

publish();
http.createServer(serve).listen(8080, '127.0.0.1', () => console.log('listening on 127.0.0.1:8080, published ' + publishes + 'x'));
JEOF

echo "[setup] the client $WORK_DIR/tools/client.js (what the job and the oracle ask the service with, from inside the sandbox)..."
cat > "$WORK_DIR/tools/client.js" <<'JEOF'
'use strict';
// client.js GET|POST PATH [gzip|plain]  -> one JSON line: status, content-encoding, content-type, nonce header, body length and sha256 of the body bytes as received
// client.js probe                        -> one deliberate fs.copyFileSync in /tmp (the oracle's control: it is the call that gVisor logs as unsupported)
const fs = require('fs'), http = require('http'), crypto = require('crypto');
const [m, p, enc] = process.argv.slice(2);
if (m === 'probe') {
  fs.writeFileSync('/tmp/probe-src', 'probe');
  fs.copyFileSync('/tmp/probe-src', '/tmp/probe-dst');
  console.log('probe done');
} else {
  const req = http.request({ host: '127.0.0.1', port: 8080, method: m, path: p, headers: { 'Accept-Encoding': enc === 'gzip' ? 'gzip' : 'identity' } }, res => {
    const chunks = [];
    res.on('data', c => chunks.push(c));
    res.on('end', () => {
      const body = Buffer.concat(chunks);
      console.log(JSON.stringify({ status: res.statusCode, encoding: res.headers['content-encoding'] || null, type: res.headers['content-type'] || null, nonce: res.headers['x-nonce'] || null, length: body.length, sha256: crypto.createHash('sha256').update(body).digest('hex'), text: body.length < 400 ? body.toString() : null }));
    });
  });
  req.on('error', e => { console.error('client: ' + e.message); process.exit(1); });
  req.end();
}
JEOF
chmod -R a+rX "$WORK_DIR/tools" "$APP"

echo "[setup] the OCI bundle: process /opt/node/bin/node /app/server.js, NONCE in the environment, the host's /usr read-only for node's libraries (lib -> usr/lib), /app and /tools read-only, /data writable, a tmpfs /tmp..."
mkdir -p "$BUNDLE/rootfs"/{proc,dev,tmp,usr,opt/node,app,tools,data}
ln -s usr/lib "$BUNDLE/rootfs/lib"
ln -s usr/lib64 "$BUNDLE/rootfs/lib64"
python3 - "$BUNDLE/config.json" "$NONCE" "$APP" "$WORK_DIR/tools" "$WORK_DIR/data" "$LIB_BASE/node" <<'PYEOF'
import json, sys
p, nonce, app, tools, data, node = sys.argv[1:7]
def bind(dst, src, ro): return {"destination": dst, "type": "bind", "source": src, "options": ["rbind", "ro" if ro else "rw"]}
c = {
  "ociVersion": "1.0.2",
  "process": {"terminal": False, "user": {"uid": 0, "gid": 0}, "args": ["/opt/node/bin/node", "/app/server.js"], "env": ["PATH=/opt/node/bin", "HOME=/tmp", "NONCE=" + nonce], "cwd": "/", "noNewPrivileges": True},
  "root": {"path": "rootfs", "readonly": True},
  "hostname": "bench57214133",
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc"},
    {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
    {"destination": "/tmp", "type": "tmpfs", "source": "tmpfs", "options": ["mode=1777"]},
    bind("/usr", "/usr", True), bind("/opt/node", node, True), bind("/app", app, True), bind("/tools", tools, True), bind("/data", data, False),
  ],
  "linux": {"namespaces": [{"type": "pid"}, {"type": "network"}, {"type": "ipc"}, {"type": "uts"}, {"type": "mount"}]},
}
json.dump(c, open(p, "w"), indent=2)
PYEOF
chmod -R a+rX "$BUNDLE"
chmod 0777 "$WORK_DIR/data"

echo "[setup] choosing the runsc platform (systrap, else ptrace) with a short smoke run of the application..."
PLATFORM=""
RS="sudo $LIB_BASE/bin/runsc --root $RUN_BASE/smoke"
for plat in systrap ptrace; do
    $RS --platform="$plat" --network=none --ignore-cgroups run -detach -bundle "$BUNDLE" smoke </dev/null >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
        if $RS --platform="$plat" --network=none --ignore-cgroups exec smoke /opt/node/bin/node /tools/client.js GET /status plain 2>/dev/null | grep -q "$NONCE"; then PLATFORM="$plat"; break; fi
        sleep 0.5
    done
    $RS --platform="$plat" --network=none --ignore-cgroups delete -force smoke >/dev/null 2>&1 || true
    [ -n "$PLATFORM" ] && break
done
sudo rm -rf "$RUN_BASE/smoke" "$WORK_DIR/data/www"
[ -n "$PLATFORM" ] || { echo "[setup] ERROR: runsc cannot run node here (neither systrap nor ptrace)"; exit 1; }
echo "  -> platform $PLATFORM ($($LIB_BASE/bin/runsc --version | head -1); node $NODE_V)"

echo "[setup] the wrapper $WORK_DIR/bin/svc (start | stop | status | exec CMD... | client ARGS...): the one way the job starts the service; it fixes runsc's flags and its debug log ($LIB_BASE/logs, emptied at every start)..."
cat > "$WORK_DIR/bin/svc" <<REOF
#!/bin/sh
# svc start|stop|status|exec CMD...|client ARGS... : the application of the bundle $BUNDLE as the sandbox "$CID" of runsc $RUNSC_V ($PLATFORM platform, no network but the sandbox's loopback)
RUNSC="sudo $LIB_BASE/bin/runsc --root $RUN_BASE/root --platform=$PLATFORM --network=none --ignore-cgroups --debug-log=$LIB_BASE/logs/ --debug"
case "\$1" in
  start)
    \$RUNSC delete -force $CID >/dev/null 2>&1
    sudo sh -c 'rm -rf "\$1"/*; exec >"\$1/run.out" 2>&1 </dev/null; shift; exec "\$@"' _ $LIB_BASE/logs \$RUNSC run -detach -bundle $BUNDLE $CID || { echo "svc: runsc failed to start the service"; exit 1; }
    for i in \$(seq 1 40); do \$RUNSC exec $CID /opt/node/bin/node /tools/client.js GET /status plain >/dev/null 2>&1 && { echo "svc: service up"; exit 0; }; sleep 0.5; done
    echo "svc: the service does not answer"; exit 1 ;;
  stop)   \$RUNSC delete -force $CID ;;
  status) \$RUNSC state $CID ;;
  exec)   shift; \$RUNSC exec $CID "\$@" ;;
  client) shift; \$RUNSC exec $CID /opt/node/bin/node /tools/client.js "\$@" ;;
  *) echo "usage: svc start|stop|status|exec CMD...|client METHOD PATH [gzip|plain]" >&2; exit 2 ;;
esac
REOF
chmod 0755 "$WORK_DIR/bin/svc"

echo "[setup] recording the state (root-only): the nonce, the platform and the hashes of the site, the client, config.json, the wrapper, node and runsc..."
sudo env STATE_DIR="$STATE_DIR" WORK_DIR="$WORK_DIR" APP="$APP" LIB_BASE="$LIB_BASE" BUNDLE="$BUNDLE" NONCE="$NONCE" PLATFORM="$PLATFORM" python3 - <<'PYEOF'
import hashlib, json, os
E = os.environ
sha = lambda p: hashlib.sha256(open(p, "rb").read()).hexdigest()
files = [E["WORK_DIR"] + "/tools/client.js", E["BUNDLE"] + "/config.json", E["WORK_DIR"] + "/bin/svc", E["LIB_BASE"] + "/bin/runsc", E["LIB_BASE"] + "/node/bin/node"]
files += [E["APP"] + "/public/" + n for n in sorted(os.listdir(E["APP"] + "/public"))]
d = {"nonce": E["NONCE"], "platform": E["PLATFORM"], "files": {f: sha(f) for f in files}}
json.dump(d, open(E["STATE_DIR"] + "/state.json", "w"), indent=1)
os.chmod(E["STATE_DIR"] + "/state.json", 0o600)
PYEOF
echo "[setup] done. The service is NOT running; its code is $APP/server.js; start it with $WORK_DIR/bin/svc start"
