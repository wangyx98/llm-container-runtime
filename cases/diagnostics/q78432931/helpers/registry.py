#!/usr/bin/env python3
"""registry.py ROOT PORT : a read-only container registry (Docker Registry HTTP API v2) on 127.0.0.1:PORT, plain HTTP.

ROOT/blobs/<hex>        a blob (layer, config or manifest), served under the digest sha256:<hex>
ROOT/rates/<hex>        optional: the rate at which the blob is served, in bytes per second (a blob without one is served at full speed)
ROOT/tags/<repo>/<tag>  the digest of the manifest a tag points to

Every block of a blob it writes to a client is logged with the time and the position reached; GET /_bench/log returns the log. The
oracle uses it as the ground truth of what was transferred, and when.
"""
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT, PORT = sys.argv[1], int(sys.argv[2])
CHUNK = 16384
LOG = []
LOCK = threading.Lock()


def log(**kw):
    kw["t"] = time.time()
    with LOCK:
        LOG.append(kw)


def read(path):
    try:
        return open(path, "rb").read()
    except OSError:
        return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, body=b"", ctype="application/json", extra=None, head=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def do_HEAD(self):
        self.route(True)

    def do_GET(self):
        self.route(False)

    def route(self, head):
        path = self.path.split("?")[0]
        if path in ("/v2", "/v2/"):
            return self.reply(200, b"{}", head=head)
        if path == "/_bench/log":
            with LOCK:
                body = json.dumps(LOG).encode()
            return self.reply(200, body, head=head)
        m = re.match(r"^/v2/(.+)/(manifests|blobs)/([^/]+)$", path)
        if not m:
            return self.reply(404, b'{"errors":[{"code":"NAME_UNKNOWN"}]}', head=head)
        name, kind, ref = m.groups()
        if kind == "manifests" and not ref.startswith("sha256:"):
            tag = read(os.path.join(ROOT, "tags", name, ref))
            if tag is None:
                return self.reply(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN"}]}', head=head)
            ref = tag.decode().strip()
        if not re.match(r"^sha256:[0-9a-f]{64}$", ref):
            return self.reply(400, b'{"errors":[{"code":"DIGEST_INVALID"}]}', head=head)
        hexd = ref.split(":")[1]
        blob = os.path.join(ROOT, "blobs", hexd)
        if not os.path.isfile(blob):
            return self.reply(404, b'{"errors":[{"code":"BLOB_UNKNOWN"}]}', head=head)
        size = os.path.getsize(blob)
        if kind == "manifests":
            ctype = json.loads(read(blob)).get("mediaType", "application/vnd.oci.image.manifest.v1+json")
        else:
            ctype = "application/octet-stream"
        start, end, code = 0, size - 1, 200
        rng = re.match(r"^bytes=(\d*)-(\d*)$", self.headers.get("Range", ""))
        if rng and kind == "blobs" and (rng.group(1) or rng.group(2)):
            start = int(rng.group(1) or 0)
            end = min(int(rng.group(2)), size - 1) if rng.group(2) else size - 1
            code = 206
        extra = {"Docker-Content-Digest": ref, "Accept-Ranges": "bytes"}
        if code == 206:
            extra["Content-Range"] = "bytes %d-%d/%d" % (start, end, size)
        length = end - start + 1
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        for k, v in extra.items():
            self.send_header(k, v)
        self.end_headers()
        if head:
            return
        rate = read(os.path.join(ROOT, "rates", hexd))
        rate = float(rate) if rate else None
        if kind == "manifests":
            rate = None
        t0, pos = time.monotonic(), start
        if rate:
            log(ev="start", d=ref, pos=pos, size=size)
        try:
            with open(blob, "rb") as f:
                f.seek(start)
                while pos <= end:
                    data = f.read(min(CHUNK, end + 1 - pos))
                    self.wfile.write(data)
                    pos += len(data)
                    if rate:
                        log(ev="chunk", d=ref, pos=pos, size=size)
                        wait = t0 + (pos - start) / rate - time.monotonic()
                        if wait > 0:
                            time.sleep(wait)
            if rate:
                log(ev="end", d=ref, pos=pos, size=size)
        except (BrokenPipeError, ConnectionResetError):
            if rate:
                log(ev="abort", d=ref, pos=pos, size=size)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64


if __name__ == "__main__":
    Server(("127.0.0.1", PORT), Handler).serve_forever()
