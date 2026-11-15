#!/usr/bin/env python3
"""Test of the update health gate (`health_ok` in unitotem/files/unitotem-update) and of the first-boot certificate: the manager's certificate is
pinned by its bytes, so a certificate whose dates are wrong for the clock (a new device with a wrong RTC) is still healthy, while a different
certificate, a missing file or a bad status is not. Local HTTPS servers on 127.0.0.1, certificates made with openssl in a temporary directory;
nothing on the host is touched.

    python3 tools/release/test_health_pin.py
"""
import http.server
import importlib.machinery
import importlib.util
import os
import ssl
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
UPDATE = os.path.join(ROOT, "unitotem", "files", "unitotem-update")
CERT_SCRIPT = os.path.join(ROOT, "unitotem", "files", "unitotem-first-boot-cert")
loader = importlib.machinery.SourceFileLoader("unitotem_update", UPDATE)
uu = importlib.util.module_from_spec(importlib.util.spec_from_loader("unitotem_update", loader))
loader.exec_module(uu)

ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond:
        ok += 1
        print("PASS:", name)
    else:
        fail += 1
        print("FAIL:", name, extra)


def make_cert(td, name, start=None, end=None):
    """cert+key PEM like /etc/ssl/unitotem.pem; start/end are openssl dates (YYYYMMDDHHMMSSZ)"""
    key, crt, pem = (os.path.join(td, f"{name}.{x}") for x in ("key", "crt", "pem"))
    cmd = ["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-keyout", key, "-out", crt, "-subj", f"/CN={name}"]
    cmd += ["-not_before", start, "-not_after", end] if start else ["-days", "30"]
    subprocess.run(cmd, check=True, capture_output=True)
    with open(pem, "w") as f:
        f.write(open(crt).read() + open(key).read())
    return pem, crt, key


class Handler(http.server.BaseHTTPRequestHandler):
    status = 200

    def do_GET(self):
        self.send_response(self.server.status)
        self.end_headers()

    def log_message(self, *a):
        pass


class Server(http.server.HTTPServer):
    def handle_error(self, request, client_address):   # the pin check opens a connection and closes it without a request
        pass


def serve(crt, key, status=200):
    srv = Server(("127.0.0.1", 0), Handler)
    srv.status = status
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def gate(srv, pem):
    return uu.health_ok({"UPDATE_HEALTH_URL": f"https://127.0.0.1:{srv.server_address[1]}/health", "UPDATE_HEALTH_CA": pem})


with tempfile.TemporaryDirectory() as td:
    good = make_cert(td, "good")
    future = make_cert(td, "future", "20990101000000Z", "20991231000000Z")
    past = make_cert(td, "past", "20000101000000Z", "20000201000000Z")
    other = make_cert(td, "other")

    s = serve(good[1], good[2])
    check("the pinned certificate answers 200: healthy", gate(s, good[0]) is True)
    check("a different certificate than the pinned one: unhealthy", gate(s, other[0]) is False)
    check("a missing certificate file: unhealthy", gate(s, os.path.join(td, "nope.pem")) is False)
    open(os.path.join(td, "junk.pem"), "w").write("not a certificate\n")
    check("an unparsable certificate file: unhealthy", gate(s, os.path.join(td, "junk.pem")) is False)
    s.shutdown()

    s = serve(future[1], future[2])
    check("a certificate that starts in the future (wrong clock) but is the pinned one: healthy", gate(s, future[0]) is True)
    s.shutdown()
    s = serve(past[1], past[2])
    check("an expired certificate that is the pinned one: healthy (the dates mean nothing, the pin identifies the server)", gate(s, past[0]) is True)
    s.shutdown()

    s = serve(good[1], good[2], status=500)
    check("the pinned server answering 500: unhealthy", gate(s, good[0]) is False)
    s.shutdown()
    check("nothing listening: unhealthy", gate(s, good[0]) is False)
    check("an empty URL means no gate", uu.health_ok({"UPDATE_HEALTH_URL": "", "UPDATE_HEALTH_CA": ""}) is True)

    # the first-boot certificate script: starts at the epoch, so it is valid whatever the clock says
    work = os.path.join(td, "script")
    os.mkdir(work)
    text = open(CERT_SCRIPT).read().replace("DEST=/etc/ssl/unitotem.pem", f"DEST={work}/unitotem.pem").replace("/etc/ssl/.unitotem-cert", f"{work}/.unitotem-cert")
    script = os.path.join(work, "gen.sh")
    open(script, "w").write(text)
    r = subprocess.run(["bash", script], capture_output=True, text=True)
    check("the first-boot certificate script runs", r.returncode == 0, r.stderr[-200:])
    dates = subprocess.run(["openssl", "x509", "-in", f"{work}/unitotem.pem", "-noout", "-startdate"], capture_output=True, text=True).stdout
    check("its notBefore is the epoch", "1970" in dates, dates)
    check("it is valid at 1970-01-02", subprocess.run(["openssl", "verify", "-attime", "86400", "-CAfile", f"{work}/unitotem.pem", f"{work}/unitotem.pem"],
                                                     capture_output=True).returncode == 0)
    check("the key stays private (0600)", oct(os.stat(f"{work}/unitotem.pem").st_mode & 0o777) == "0o600")

print(f"\n{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
