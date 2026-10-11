"""collector.py PORT FILE : the lab's local JSON collector. Fluent Bit's http output (format json_lines) POSTs to it; every line of every body
(one JSON record per line) is appended to FILE, in the order received. POST /reset empties FILE; GET / answers the number of lines."""
import http.server
import os
import sys
import threading

port, path = int(sys.argv[1]), sys.argv[2]
lock = threading.Lock()
open(path, "ab").close()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, text):
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        with lock:
            self.reply(str(open(path, "rb").read().count(b"\n")) + "\n")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with lock:
            if self.path.startswith("/reset"):
                open(path, "wb").close()
            else:
                with open(path, "ab") as f:
                    f.write(body if body.endswith(b"\n") else body + b"\n")
        self.reply("ok\n")


http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
