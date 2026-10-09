#!/usr/bin/env python3

import argparse
import json
import ssl
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROBE = b"ipod-ios-browser-write-probe-v1\n"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def do_GET(self):
        if self.path == "/api/status":
            self.send_json({"ok": True, "probe": PROBE.decode().strip()})
            return
        if self.path == "/probe.txt":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="ipod-ios-probe.txt"')
            self.send_header("Content-Length", str(len(PROBE)))
            self.end_headers()
            self.wfile.write(PROBE)
            return
        super().do_GET()

    def send_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, message, *args):
        print(f"{self.client_address[0]} - {message % args}")


def main():
    parser = argparse.ArgumentParser(description="Serve the iPhone/iPod browser feasibility probe")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--cert", type=Path)
    parser.add_argument("--key", type=Path)
    args = parser.parse_args()

    if bool(args.cert) != bool(args.key):
        parser.error("--cert and --key must be provided together")

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    scheme = "http"
    if args.cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        scheme = "https"

    print(f"Open {scheme}://<this-machine-ip>:{args.port} on the iPhone")
    server.serve_forever()


if __name__ == "__main__":
    main()
