"""dist.py ADDR PORT ZIP CRT KEY LOG : the download site of the lab, HTTPS on ADDR:PORT. It serves one file, /distributions/gradle-7.0.2-bin.zip (ZIP), to anybody that can connect.
Every request is one line of LOG: time, client address, method, path, status, bytes sent."""
import http.server
import ssl
import sys
import threading
import time

addr, port, zip_path, crt, key, log = sys.argv[1:7]
port = int(port)
lock = threading.Lock()
BODY = open(zip_path, "rb").read()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def note(self, status, sent):
        with lock, open(log, "a") as f:
            f.write("%s %s %s %s %d %d\n" % (time.strftime("%H:%M:%S"), self.client_address[0], self.command, self.path, status, sent))

    def serve(self, head):
        if self.path != "/distributions/gradle-7.0.2-bin.zip":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.note(404, 0)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        if not head:
            self.wfile.write(BODY)
        self.note(200, 0 if head else len(BODY))

    def do_GET(self):
        self.serve(False)

    def do_HEAD(self):
        self.serve(True)

    def log_message(self, *a):
        pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(crt, key)
srv = Server((addr, port), Handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
