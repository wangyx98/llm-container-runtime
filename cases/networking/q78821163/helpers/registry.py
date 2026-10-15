"""registry.py HOST PORT ROOT LOG CERT KEY : the private registry of the lab, HTTPS (no authentication), the repositories of the blob store mkoci.py made in ROOT (manifests by tag or
digest, blobs by digest; GET and HEAD). tags.json is read at every request, so images added later (mkoci.py add) are served at once.

Every request is logged in LOG as one JSON object {"event": "request", "method", "path", "status", "src", "ua", "t"}; a TLS handshake that fails is logged as {"event": "tls_error",
"src", "error"}. Requests of the lab itself (User-Agent bench78821163-lab) are not logged."""
import json
import os
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

host, port, root, log, cert, key = sys.argv[1:7]
port = int(port)
blobs = os.path.join(root, "blobs", "sha256")
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)


def note(**kw):
    kw["t"] = round(time.time(), 3)
    with open(log, "a") as f:
        f.write(json.dumps(kw) + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code, body=b"", ctype="application/json", extra=()):
        ua = self.headers.get("User-Agent", "")
        if not ua.startswith("bench78821163-lab"):
            note(event="request", method=self.command, path=self.path, status=code, src=self.client_address[0], ua=ua)
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
        parts = path.split("/")                      # "", "v2", REPO, KIND, REF
        if len(parts) != 5 or parts[1] != "v2" or parts[2] not in tags:
            return self.reply(404, b'{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}')
        repo, kind, ref = parts[2], parts[3], parts[4]
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

    def log_message(self, *a):
        pass


class S(ThreadingHTTPServer):
    daemon_threads = True

    def get_request(self):
        sock, addr = self.socket.accept()
        return ctx.wrap_socket(sock, server_side=True), addr

    def handle_error(self, request, client_address):
        note(event="tls_error", src=client_address[0], error=str(sys.exc_info()[1])[:120])


S((host, port), H).serve_forever()
