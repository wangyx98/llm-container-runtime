"""registry.py HOST PORT ROOT LOG CERT KEY ALLOWED_SRC : the registry of the lab, HTTPS only (a protocol fixture of the Docker registry API v2): the repositories of the blob store mkoci.py
made in ROOT (manifests by tag or digest, blobs by digest; GET and HEAD). tags.json is read at every request, so images added later (mkoci.py add) are served at once.

It is reachable from ONE address only: a connection whose source address is not ALLOWED_SRC (the source address of the lab's proxy) is reset before any TLS happens and logged as
{"event": "direct", "peer", "port"} (the controlled egress: whoever is not the proxy does not get through). Every request of the proxy is logged as {"event": "request", "method", "path",
"status", "ua"} in LOG, one JSON object per line. Requests of the lab itself (User-Agent bench73394153-lab) are not logged."""
import json
import os
import socket
import ssl
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

host, port, root, log, cert, key, allowed = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
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
        if not ua.startswith("bench73394153-lab"):
            note(event="request", method=self.command, path=self.path, status=code, ua=ua[:60])
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

    def log_message(self, *a):
        pass


class S(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def get_request(self):
        sock, addr = self.socket.accept()
        if addr[0] != allowed:
            note(event="direct", peer=addr[0], port=addr[1])
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))      # reset, as a firewall that rejects
            sock.close()
            raise OSError("not the proxy")
        return ctx.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr


S((host, port), H).serve_forever()
