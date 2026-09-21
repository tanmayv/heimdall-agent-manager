#!/usr/bin/env python3
"""Echo server for the REQ-XM-4 proxy path end-to-end test.

Runs as the kind=server shell session on the TARGET bridge (bridge B). It returns
the request body back verbatim, so a client on another bridge can prove that what it
sent is exactly what came back across bridge A -> hub -> bridge B and all the way
back.

Deliberately dependency-free (stdlib only) so it can run as a bridge session command
on any host in the dev stack.

  usage: xm4_echo_server.py <port>

Routes:
  POST/PUT /echo  -> 200, body echoed back byte-for-byte
  GET      /ping  -> 200, "pong" (liveness, used before the echo round trips start)
"""
import http.server
import socketserver
import sys


class EchoHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # keep the session log quiet
        pass

    def _echo(self):
        length = int(self.headers.get("Content-Length") or 0)
        # Read exactly Content-Length bytes; anything else would desynchronise a
        # keep-alive connection and mask a truncation bug as a hang.
        body = self.rfile.read(length) if length else b""
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_POST(self):
        self._echo()

    def do_PUT(self):
        self._echo()

    def do_GET(self):
        body = b"pong"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1])
    Server(("127.0.0.1", port), EchoHandler).serve_forever()
