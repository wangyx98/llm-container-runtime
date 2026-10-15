"""registry.py HOST PORT ROOT LOG : the registry of the lab, plain HTTP (no TLS, no authentication), for the repositories of the blob store that mkimage.py fills in ROOT (ROOT/tags.json maps
{repository: {tag: digest}}, ROOT/blobs/sha256/DIGEST holds manifests, indexes and blobs). GET and HEAD; a blob is served whole or, with a Range header, in ranges (206), as real registries do.
tags.json is read at every request, so images added later (mkimage.py add) are served at once.

Every request is logged in LOG as one JSON object {"event": "request", "method", "path", "status", "src", "ua", "range", "sent", "t"}: "sent" is what was really written to the client (a client that
gives up in the middle of a blob leaves a smaller number than the blob's size). A TLS ClientHello on this plain HTTP port is logged as {"event": "tls_client", "src"} (what a client that expects
HTTPS sends) and answered like a Go HTTP server does (400, not HTTP/TLS). Requests of the lab itself (User-Agent bench78631941-lab) are not logged."""
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

    def reply(self, code, body=b"", ctype="application/json", extra=(), path=None, start=0, end=None):
        """body: bytes, or (file path, start, end) for a part of a blob that is sent in chunks"""
        size = len(body) if isinstance(body, bytes) else end - start + 1
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.send_header("Docker-Distribution-Api-Version", "registry/2.0")
        for k, v in extra:
            self.send_header(k, v)
        sent = 0
        try:
            self.end_headers()
            if self.command != "HEAD":
                if isinstance(body, bytes):
                    self.wfile.write(body)
                    sent = size
                else:
                    with open(path, "rb") as f:
                        f.seek(start)
                        left = size
                        while left > 0:
                            chunk = f.read(min(1 << 16, left))
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            sent += len(chunk)
                            left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        ua = self.headers.get("User-Agent", "")
        if not ua.startswith("bench78631941-lab"):
            note(event="request", method=self.command, path=self.path, status=code, src=self.client_address[0], ua=ua, range=self.headers.get("Range"), sent=sent)

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
        f = os.path.join(blobs, ref[7:]) if ref.startswith("sha256:") else ""
        if kind == "blobs" and os.path.isfile(f):
            size = os.path.getsize(f)
            rng = self.headers.get("Range", "")
            if rng.startswith("bytes="):
                a, _, b = rng[6:].partition("-")
                a = int(a)
                b = min(int(b) if b else size - 1, size - 1)
                if a > b:
                    return self.reply(416, b"")
                return self.reply(206, (f, a, b), "application/octet-stream",
                                  (("Content-Range", "bytes %d-%d/%d" % (a, b, size)), ("Accept-Ranges", "bytes"), ("Docker-Content-Digest", ref)), path=f, start=a, end=b)
            return self.reply(200, (f, 0, size - 1), "application/octet-stream", (("Accept-Ranges", "bytes"), ("Docker-Content-Digest", ref)), path=f, start=0, end=size - 1)
        return self.reply(404, b'{"errors":[{"code":"BLOB_UNKNOWN","message":"blob unknown"}]}')

    do_GET = do_HEAD = handle_one

    def log_message(self, *a):
        pass

    def log_error(self, *a):
        pass

    def handle_one_request(self):
        try:
            line = self.rfile.peek(1)[:1] if hasattr(self.rfile, "peek") else b""
        except OSError:
            line = b""
        if line == b"\x16":                           # a TLS ClientHello: the client expects HTTPS on this port
            note(event="tls_client", src=self.client_address[0])
            try:                                          # what a Go HTTP server answers to bytes that are not HTTP: the client says "server gave HTTP response to HTTPS client"
                self.wfile.write(b"HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
            self.close_connection = True
            return
        super().handle_one_request()


class S(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64


S((host, port), H).serve_forever()
