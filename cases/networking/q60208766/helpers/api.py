"""api.py HOST PORT CERT KEY TOKEN LOG SEED : the Kubernetes API of the lab (a small in-memory fixture, HTTPS, bearer token). It serves what the Calico CNI plugin reads and writes in
Kubernetes-datastore mode: the objects of SEED (a JSON file: {"path of the collection": [objects]}) and whatever is created later (POST), updated (PUT, resourceVersion checked), read
(GET one or list) or deleted. Every request is logged as one JSON object per line in LOG: {"t","event":"api","method","path","status","auth":"ok|bad","client","ua"}."""
import json
import re
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

host, port, cert, key, token, log, seed = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
LOCK = threading.Lock()
STORE = {}      # collection path -> {name: object}
RV = [1000]
CRD = "crd.projectcalico.org/v1"
KINDS = {"/apis/%s/%s" % (CRD, r): (CRD, k) for r, k in (
    ("clusterinformations", "ClusterInformation"), ("ippools", "IPPool"), ("blockaffinities", "BlockAffinity"), ("ipamblocks", "IPAMBlock"), ("ipamhandles", "IPAMHandle"),
    ("ipamconfigs", "IPAMConfig"), ("nodes", "Node"), ("hostendpoints", "HostEndpoint"), ("felixconfigurations", "FelixConfiguration"), ("bgpconfigurations", "BGPConfiguration"),
    ("networkpolicies", "NetworkPolicy"), ("globalnetworkpolicies", "GlobalNetworkPolicy"))}
KINDS.update({"/api/v1/nodes": ("v1", "Node"), "/api/v1/namespaces": ("v1", "Namespace")})


def note(**kw):
    kw["t"] = round(time.time(), 3)
    kw["event"] = "api"
    with LOCK, open(log, "a") as f:
        f.write(json.dumps(kw) + "\n")


def split(path):
    """(collection path, name or None, subresource or None)"""
    p = [x for x in path.split("/") if x]
    if p[:2] == ["api", "v1"]:
        rest, base = p[2:], "/api/v1"
    elif p[:1] == ["apis"] and len(p) >= 3:
        rest, base = p[3:], "/apis/%s/%s" % (p[1], p[2])
    else:
        return None
    if rest[:1] == ["namespaces"] and len(rest) >= 3:
        base += "/namespaces/" + rest[1]
        rest = rest[2:]
    if not rest:
        return None
    return base + "/" + rest[0], (rest[1] if len(rest) > 1 else None), (rest[2] if len(rest) > 2 else None)


def stamp(coll, name, obj):
    RV[0] += 1
    md = obj.setdefault("metadata", {})
    md["name"] = name
    md["resourceVersion"] = str(RV[0])
    md.setdefault("uid", "00000000-0000-4000-8000-%012d" % RV[0])
    md.setdefault("creationTimestamp", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    if "/namespaces/" in coll:
        md["namespace"] = coll.split("/namespaces/")[1].split("/")[0]
    return obj


for coll, objs in json.load(open(seed)).items():
    for o in objs:
        STORE.setdefault(coll, {})[o["metadata"]["name"]] = stamp(coll, o["metadata"]["name"], o)
        KINDS[coll] = (o.get("apiVersion", "v1"), o.get("kind", "Object"))


def merge(dst, patch):
    """JSON merge patch (null deletes a key); lists are replaced, as the Kubernetes merge patch does it"""
    for k, v in patch.items():
        if v is None:
            dst.pop(k, None)
        elif isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v


def status(code, reason, msg):
    return code, {"kind": "Status", "apiVersion": "v1", "metadata": {}, "status": "Failure", "message": msg, "reason": reason, "code": code}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self, method):
        u = urlsplit(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        auth = "ok" if self.headers.get("Authorization") == "Bearer " + token else "bad"
        if auth != "ok":
            code, body = status(401, "Unauthorized", "Unauthorized")
        else:
            code, body = self.dispatch(method, u.path, raw)
        note(method=method, path=u.path, status=code, auth=auth, client=self.client_address[0], ua=self.headers.get("User-Agent", "")[:60])
        self.reply(code, body)

    def dispatch(self, method, path, raw):
        if path in ("/version",):
            return 200, {"major": "1", "minor": "30", "gitVersion": "v1.30.0"}
        sp = split(path)
        if not sp:
            return status(404, "NotFound", "the server could not find the requested resource")
        coll, name, sub = sp
        with LOCK:
            items = STORE.setdefault(coll, {})
            if method == "GET" and name is None:
                av, kind = KINDS.get(coll, ("v1", "Object"))
                return 200, {"kind": kind + "List", "apiVersion": av, "metadata": {"resourceVersion": str(RV[0])}, "items": list(items.values())}
            if method == "GET":
                if name not in items:
                    return status(404, "NotFound", '%s "%s" not found' % (coll.rsplit("/", 1)[1], name))
                return 200, items[name]
            try:
                obj = json.loads(raw) if raw else {}
            except ValueError:
                return status(400, "BadRequest", "bad body")
            if method == "POST" and name is None:
                nm = obj.get("metadata", {}).get("name")
                if not nm:
                    return status(422, "Invalid", "metadata.name is required")
                if nm in items:
                    return status(409, "AlreadyExists", '%s "%s" already exists' % (coll.rsplit("/", 1)[1], nm))
                KINDS.setdefault(coll, (obj.get("apiVersion", "v1"), obj.get("kind", "Object")))
                items[nm] = stamp(coll, nm, obj)
                return 201, items[nm]
            if method == "PUT" and name is not None:
                if name not in items:
                    return status(404, "NotFound", '%s "%s" not found' % (coll.rsplit("/", 1)[1], name))
                have, want = items[name]["metadata"]["resourceVersion"], obj.get("metadata", {}).get("resourceVersion")
                if want and want != have:
                    return status(409, "Conflict", "Operation cannot be fulfilled on %s %s: the object has been modified" % (coll.rsplit("/", 1)[1], name))
                if sub == "status":
                    merged = dict(items[name])
                    merged["status"] = obj.get("status", {})
                    obj = merged
                if "metadata" in items[name]:
                    obj.setdefault("metadata", {}).setdefault("uid", items[name]["metadata"].get("uid"))
                    obj["metadata"].setdefault("creationTimestamp", items[name]["metadata"].get("creationTimestamp"))
                items[name] = stamp(coll, name, obj)
                return 200, items[name]
            if method == "PATCH" and name is not None:
                if name not in items:
                    return status(404, "NotFound", '%s "%s" not found' % (coll.rsplit("/", 1)[1], name))
                merge(items[name], obj)
                items[name] = stamp(coll, name, items[name])
                return 200, items[name]
            if method == "DELETE" and name is not None:
                if name not in items:
                    return status(404, "NotFound", '%s "%s" not found' % (coll.rsplit("/", 1)[1], name))
                return 200, items.pop(name)
        return status(405, "MethodNotAllowed", "method not allowed")

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")

    def do_PATCH(self):
        self.handle_any("PATCH")


class S(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


srv = S((host, port), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
