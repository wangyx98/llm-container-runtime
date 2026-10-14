"""registry.py HOST PORT ROOT LOG : the private registry of the lab, plain HTTP (no TLS), no authentication, a protocol fixture of the Docker registry API v2 (the original registry is Harbor;
nothing here depends on a Harbor feature): the repositories of the blob store mkoci.py made in ROOT (names of several segments, like calculator/app2; manifests by tag or digest, blobs by
digest; GET and HEAD). tags.json is read at every request, so images added later (mkoci.py add) are served at once.

Every request is logged as {"event": "request", "method", "path", "status", "host"} in LOG, one JSON object per line ("host" is the Host header the client sent: with a reference without a
port it carries no port); a connection that is not HTTP (a TLS client hello) is logged as {"event": "tls_hello"}. Requests of the lab itself (User-Agent bench72528378-lab) are not logged."""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

host, port, root, log = sys.argv[1:5]
port = int(port)
blobs = os.path.join(root, "blobs", "sha256")


def note(**kw):
    kw["t"] = round(time.time(), 3)
    with open(log, "a") as f:
        f.write(json.dumps(kw) + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code, body=b"", ctype="application/json", extra=()):
        if not self.headers.get("User-Agent", "").startswith("bench72528378-lab"):
            note(event="request", method=self.command, path=self.path, status=code, host=self.headers.get("Host", ""))
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
        tags = json.load(open(os.path.join(root, "tags.json")))
        path = self.path.split("?")[0]
        if path.rstrip("/") == "/v2":
            return self.reply(200, b"{}")
        parts = path.split("/")                      # "", "v2", NAME..., KIND, REF
        if len(parts) < 5 or parts[1] != "v2" or "/".join(parts[2:-2]) not in tags:
            return self.reply(404, b'{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}')
        repo, kind, ref = "/".join(parts[2:-2]), parts[-2], parts[-1]
        if kind == "manifests":
            digest = tags[repo].get(ref, ref)
            f = os.path.join(blobs, digest.split(":", 1)[-1])
            if not digest.startswith("sha256:") or not os.path.isfile(f):
                return self.reply(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}')
            data = open(f, "rb").read()
            return self.reply(200, data, json.loads(data)["mediaType"], (("Docker-Content-Digest", digest),))
        if kind == "blobs" and ref.startswith("sha256:") and os.path.isfile(os.path.join(blobs, ref[7:])):
            return self.reply(200, open(os.path.join(blobs, ref[7:]), "rb").read(), "application/octet-stream", (("Docker-Content-Digest", ref),))
        return self.reply(404, b'{"errors":[{"code":"BLOB_UNKNOWN","message":"blob unknown"}]}')

    do_GET = do_HEAD = handle_one

    def handle_one_request(self):
        try:
            first = self.rfile.peek(1)[:1]
        except (OSError, ValueError):
            first = b""
        if first == b"\x16":                         # a TLS ClientHello: the client speaks https to a plain HTTP server
            note(event="tls_hello")
            self.wfile.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            self.close_connection = True
            return
        super().handle_one_request()

    def log_message(self, *a):
        pass


ThreadingHTTPServer((host, port), H).serve_forever()
