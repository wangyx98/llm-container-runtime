#!/usr/bin/env python3
"""
A tiny read-only image registry that plays the "insecure registry" in case
q74562978. It serves exactly one repository (one tag, one manifest, its
blobs) out of a directory that setup.sh prepares, over plain HTTP, and
appends one line per request ("METHOD /path?query") to a log file, so a
checker can tell whether a pull really went through it. It never speaks TLS:
a client that opens with a TLS handshake gets an HTTP 400 back, like a real
registry on a plain-HTTP port, so that containerd reports "http: server gave
HTTP response to HTTPS client".

  registry_server.py --dir DIR --port PORT --log LOGFILE

DIR holds index.json:
  {"repo": "library/x", "tag": "latest",
   "manifest": {"digest": "sha256:...", "type": "<media type>", "file": "manifest.json"},
   "blobs": {"sha256:...": "blobs/<file>"}}
"""

import argparse
import json
import os
import re
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--log", required=True)
    args = ap.parse_args()

    with open(os.path.join(args.dir, "index.json")) as f:
        index = json.load(f)
    repo, tag = index["repo"], index["tag"]
    man = index["manifest"]
    with open(os.path.join(args.dir, man["file"]), "rb") as f:
        manifest_body = f.read()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):   # keep stderr quiet; the request log is ours
            pass

        def handle_one_request(self):
            # A client that expects HTTPS opens with a TLS ClientHello (first
            # byte 0x16). A real registry on a plain-HTTP port answers that
            # with an HTTP error, which is what makes Go clients (containerd,
            # docker) report "server gave HTTP response to HTTPS client".
            # Do the same, and keep it out of the request log (it is not a
            # request for anything).
            try:
                first = self.connection.recv(1, socket.MSG_PEEK)
            except OSError:
                self.close_connection = True
                return
            if first == b"\x16":
                body = b"400 Bad Request"
                self.connection.sendall(
                    b"HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\n"
                    b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
                self.close_connection = True
                return
            super().handle_one_request()

        def _reply(self, code, body, ctype, extra=None, head=False):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def _serve(self, head):
            with LOCK:
                with open(args.log, "a") as lf:
                    lf.write("%s %s\n" % (self.command, self.path))
            path = self.path.split("?", 1)[0]
            if path in ("/v2", "/v2/"):
                return self._reply(200, b"{}", "application/json", head=head)
            m = re.fullmatch(r"/v2/(.+)/manifests/(.+)", path)
            if m and m.group(1) == repo and m.group(2) in (tag, man["digest"]):
                return self._reply(200, manifest_body, man["type"],
                                   {"Docker-Content-Digest": man["digest"]}, head)
            m = re.fullmatch(r"/v2/(.+)/blobs/(sha256:[0-9a-f]{64})", path)
            if m and m.group(1) == repo and m.group(2) in index["blobs"]:
                with open(os.path.join(args.dir, index["blobs"][m.group(2)]), "rb") as f:
                    body = f.read()
                return self._reply(200, body, "application/octet-stream",
                                   {"Docker-Content-Digest": m.group(2)}, head)
            err = json.dumps({"errors": [{"code": "NAME_UNKNOWN", "message": "not found"}]}).encode()
            return self._reply(404, err, "application/json", head=head)

        def do_GET(self):
            self._serve(False)

        def do_HEAD(self):
            self._serve(True)

    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
