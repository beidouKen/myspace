#!/usr/bin/env python3
"""Minimal HTTP server that accepts POST /infer and never responds (for 504 sync_wait_timeout test)."""
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/infer":
            import time
            time.sleep(999)
        self.send_response(200)
        self.end_headers()
    def log_message(self, *args): pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    s = HTTPServer(("127.0.0.1", port), Handler)
    if port == 0:
        print(s.socket.getsockname()[1], flush=True)
    s.serve_forever()
