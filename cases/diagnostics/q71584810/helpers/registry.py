"""registry.py PORT : a stand-in for an image registry that does not let pulls through. It listens on 127.0.0.1:PORT (plain HTTP) and answers
every request for a repository by the first element of the repository name: "throttled" -> 429 Too Many Requests (Retry-After: 30), "denied" ->
403 Forbidden, "down" -> 503 Service Unavailable; GET /v2/ -> 200. Each request is logged on stdout, one line (the unit's journal keeps it)."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODES = {"throttled": (429, "Too Many Requests", "TOOMANYREQUESTS", "pull rate limit exceeded"),
         "denied": (403, "Forbidden", "DENIED", "pull access denied"),
         "down": (503, "Service Unavailable", "UNAVAILABLE", "registry is not available")}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_one(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        if self.path.rstrip("/") == "/v2":
            code, reason, body = 200, "OK", b"{}"
        elif len(parts) > 2 and parts[0] == "v2" and parts[1] in MODES:
            code, reason, err, msg = MODES[parts[1]]
            body = json.dumps({"errors": [{"code": err, "message": msg}]}).encode()
        else:
            code, reason, body = 404, "Not Found", b'{"errors":[{"code":"NAME_UNKNOWN","message":"repository name not known to registry"}]}'
        print("registry: %s %s -> %d %s" % (self.command, self.path, code, reason), flush=True)
        self.send_response(code, reason)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if code == 429:
            self.send_header("Retry-After", "30")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    do_GET = do_HEAD = do_POST = handle_one

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
