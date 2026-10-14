"""registry.py HOST PORT ROOT LOG GOOD_CERT GOOD_KEY BAD_CERT BAD_KEY SELFILE USER PASSWORD : the private registry of the lab, HTTPS with HTTP basic authentication, the repositories of the blob store
mkoci.py made in ROOT (manifests by tag or digest, blobs by digest; GET and HEAD).

Every request needs the credentials USER:PASSWORD (401 with a basic challenge otherwise). The certificate it presents depends on the content of SELFILE at the moment of each connection:
"good" (anything else): the certificate of the lab's CA, "bad": a certificate for the same name signed by ANOTHER CA that nobody trusts (the negative control of the oracle: a node that
still connects has stopped verifying). Every request is logged as {"event": "request", "method", "path", "status", "auth": "ok"|"none"|"bad", "cert": "good"|"bad"} in LOG, one JSON object per
line. Requests of the lab itself (User-Agent bench71671179-lab) are not logged."""
import base64
import json
import os
import socket
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

host, port, root, log, gcert, gkey, bcert, bkey, selfile, user, password = sys.argv[1:12]
port = int(port)
tags = json.load(open(os.path.join(root, "tags.json")))
blobs = os.path.join(root, "blobs", "sha256")
want = "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
ctxs = {}
for name, c, k in (("good", gcert, gkey), ("bad", bcert, bkey)):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(c, k)
    ctxs[name] = ctx


def selected():
    try:
        return "bad" if open(selfile).read().strip() == "bad" else "good"
    except OSError:
        return "good"


def note(**kw):
    kw["t"] = round(time.time(), 3)
    with open(log, "a") as f:
        f.write(json.dumps(kw) + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, code, body=b"", ctype="application/json", extra=(), auth="ok"):
        if not self.headers.get("User-Agent", "").startswith("bench71671179-lab"):
            note(event="request", method=self.command, path=self.path, status=code, auth=auth, cert=getattr(self.request, "bench_cert", "good"))
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Docker-Distribution-Api-Version", "registry/2.0")
        self.send_header("Connection", "close")                # no kept-alive connection: every request is a new TLS handshake, so what the node trusts is judged every time
        self.close_connection = True
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle_one(self):
        got = self.headers.get("Authorization")
        if got != want:
            return self.reply(401, b'{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}', extra=(("WWW-Authenticate", 'Basic realm="bench71671179"'),),
                              auth="none" if not got else "bad")
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
        name = selected()
        ss = ctxs[name].wrap_socket(sock, server_side=True, do_handshake_on_connect=False)
        ss.bench_cert = name
        return ss, addr


S((host, port), H).serve_forever()
