"""registry.py PORT ROOT LOG : a small registry of the lab (plain HTTP on 127.0.0.1:PORT). It serves the repository bench56996594/marker from the blob store
mkoci.py made in ROOT (manifests by tag or digest, blobs by digest; GET and HEAD) and appends one line per request to LOG: "METHOD PATH STATUS".
Every other repository is "name unknown" (404)."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, root, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
REPO = "bench56996594/marker"
tags = json.load(open(os.path.join(root, "tags.json")))
blobs = os.path.join(root, "blobs", "sha256")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code, body=b"", ctype="application/json", extra=()):
        if not self.headers.get("User-Agent", "").startswith("bench56996594-lab"):   # the lab's own requests (lab.py check) are not pulls
            with open(log, "a") as f:
                f.write("%s %s %d\n" % (self.command, self.path, code))
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Docker-Distribution-Api-Version", "registry/2.0")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle_one(self):
        path = self.path.split("?")[0]
        if path.rstrip("/") == "/v2":
            return self.reply(200, b"{}")
        pre = "/v2/%s/" % REPO
        if not path.startswith(pre):
            return self.reply(404, b'{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}')
        kind, _, ref = path[len(pre):].partition("/")
        if kind == "manifests":
            digest = tags.get(ref, ref)
            f = os.path.join(blobs, digest.split(":", 1)[-1])
            if not digest.startswith("sha256:") or not os.path.isfile(f):
                return self.reply(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}')
            data = open(f, "rb").read()
            return self.reply(200, data, json.loads(data)["mediaType"], (("Docker-Content-Digest", digest),))
        if kind == "blobs" and ref.startswith("sha256:") and os.path.isfile(os.path.join(blobs, ref[7:])):
            return self.reply(200, open(os.path.join(blobs, ref[7:]), "rb").read(), "application/octet-stream", (("Docker-Content-Digest", ref),))
        return self.reply(404, b'{"errors":[{"code":"BLOB_UNKNOWN","message":"blob unknown"}]}')

    do_GET = do_HEAD = handle_one

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
