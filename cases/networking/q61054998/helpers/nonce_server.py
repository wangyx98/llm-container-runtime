"""nonce_server.py PORT NONCE_FILE : the service on the host's loopback address (127.0.0.1:PORT). Every connection gets the current content of NONCE_FILE as one line, and is closed.
The lab changes the file (lab.py rotate); a client in another network namespace cannot connect at all."""
import socketserver
import sys

port, nonce_file = int(sys.argv[1]), sys.argv[2]


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.sendall((open(nonce_file).read().strip() + "\n").encode())
        except OSError:
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


Server(("127.0.0.1", port), Handler).serve_forever()
