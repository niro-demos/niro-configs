#!/usr/bin/env python3
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


RUN_DIR = "/run/webhook"
EVENTS_PATH = os.path.join(RUN_DIR, "events.jsonl")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        event = {
            "time": time.time(),
            "path": self.path,
            "method": "POST",
            "headers": dict(self.headers.items()),
            "body": body.decode("utf-8", errors="replace"),
        }
        os.makedirs(RUN_DIR, exist_ok=True)
        with open(EVENTS_PATH, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(event, separators=(",", ":")) + "\n")

        if self.path == "/always-fail":
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"intentional harness failure")
            return
        if self.path == "/success":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"accepted")
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, _format, *_args):
        return


if __name__ == "__main__":
    os.makedirs(RUN_DIR, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", 19080), Handler).serve_forever()
