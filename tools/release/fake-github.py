#!/usr/bin/env python3
"""Minimal stand-in for GitHub Releases, for testing the update client offline.

Serves the layout `unitotem-release build` produces (ROOT/vX.Y.Z/<assets>) under the same URLs GitHub uses:
  /<owner>/<repo>/releases/latest/download/<asset>   -> 302 to the newest non-PRERELEASE tag
  /<owner>/<repo>/releases/download/<tag>/<asset>    -> 302 to /objects/<tag>/<asset>  (GitHub redirects
                                                         to a different host here; same shape, same host)
  /objects/<tag>/<asset>                             -> the bytes, with Range support
It does NOT reproduce rate limits, the 2 GiB asset cap or api.github.com. Plain HTTP on purpose: the
signature, not TLS, is what the client must rely on.
"""
import argparse, os, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def tags(root):
    def key(t): return [int(x) if x.isdigit() else x for x in re.split(r"[.\-]", t[1:])]
    return sorted((t for t in os.listdir(root) if t.startswith("v") and os.path.isdir(os.path.join(root, t))), key=key)


class H(BaseHTTPRequestHandler):
    root = "."

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def redirect(self, to):
        self.send_response(302); self.send_header("Location", to); self.send_header("Content-Length", "0"); self.end_headers()

    def do_HEAD(self): self.do_GET(head=True)

    def do_GET(self, head=False):
        p = self.path.split("?")[0]
        m = re.fullmatch(r"/([^/]+)/([^/]+)/releases/latest/download/([^/]+)", p)
        if m:
            stable = [t for t in tags(self.root) if not os.path.exists(os.path.join(self.root, t, "PRERELEASE"))]
            if not stable: return self.send_error(404)
            return self.redirect(f"/{m[1]}/{m[2]}/releases/download/{stable[-1]}/{m[3]}")
        m = re.fullmatch(r"/([^/]+)/([^/]+)/releases/download/(v[^/]+)/([^/]+)", p)
        if m:
            return self.redirect(f"/objects/{m[3]}/{m[4]}")
        m = re.fullmatch(r"/objects/(v[^/]+)/([^/]+)", p)
        if not m: return self.send_error(404)
        path = os.path.join(self.root, m[1], m[2])
        if not os.path.isfile(path): return self.send_error(404)
        size = os.path.getsize(path); start, end, code = 0, size - 1, 200
        r = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if r and (r[1] or r[2]):
            if r[1]: start = int(r[1]); end = int(r[2]) if r[2] else size - 1
            else: start = max(0, size - int(r[2]))
            if start >= size: self.send_response(416); self.send_header("Content-Range", f"bytes */{size}"); self.end_headers(); return
            end = min(end, size - 1); code = 206
        self.send_response(code)
        self.send_header("Content-Type", "application/octet-stream"); self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if code == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head: return
        with open(path, "rb") as f:
            f.seek(start); left = end - start + 1
            while left:
                b = f.read(min(1 << 20, left))
                if not b: break
                try: self.wfile.write(b)
                except (BrokenPipeError, ConnectionResetError): return
                left -= len(b)


ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--root", required=True, help="directory containing vX.Y.Z/ release dirs")
ap.add_argument("--bind", default="192.168.122.1"); ap.add_argument("--port", type=int, default=8080)
a = ap.parse_args(); H.root = a.root
print(f"fake-github on http://{a.bind}:{a.port}/ (root={a.root})", file=sys.stderr)
ThreadingHTTPServer((a.bind, a.port), H).serve_forever()
