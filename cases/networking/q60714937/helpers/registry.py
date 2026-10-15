"""registry.py HOST PORT ROOT LOG : the private registry of the lab, plain HTTP (no TLS), no authentication, a protocol fixture of the Docker registry API v2: the repositories of the blob
store mkoci.py made in ROOT (manifests by tag or digest, blobs by digest; GET and HEAD). tags.json is read at every request, so images added later (mkoci.py add) are served at once.

It listens on HOST (the address of the Docker network of the cluster on this machine, which the nodes reach; it may not be configured yet, so the socket is bound with IP_FREEBIND). Every
request is logged as {"event": "request", "method", "path", "status", "client", "ua"} in LOG, one JSON object per line ("client" is the address of the peer: the node that asks); a
connection that is not HTTP (a TLS client hello) is logged as {"event": "tls_hello", "client"} and answered with the bytes of an HTTP error: that is what a client gets that tries https
against this server ("http: server gave HTTP response to HTTPS client"). Requests of the lab itself (User-Agent bench60714937-lab) are not logged."""
import json
import os
import socket
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
        ua = self.headers.get("User-Agent", "")
        if not ua.startswith("bench60714937-lab"):
            note(event="request", method=self.command, path=self.path, status=code, client=self.client_address[0], ua=ua[:60])
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
        parts = path.split("/")[2:]                  # REPO (one or more segments), KIND, REF
        if len(parts) < 3 or path.split("/")[1] != "v2":
            return self.reply(404, b'{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}')
        repo, kind, ref = "/".join(parts[:-2]), parts[-2], parts[-1]
        if repo not in tags:
            return self.reply(404, b'{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}')
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
            note(event="tls_hello", client=self.client_address[0])
            self.wfile.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            self.close_connection = True
            return
        super().handle_one_request()

    def log_message(self, *a):
        pass


class S(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IP, 15, 1)     # IP_FREEBIND: the address of the Docker network may appear after this process starts
        super().server_bind()


S((host, port), H).serve_forever()
