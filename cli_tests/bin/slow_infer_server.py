#!/usr/bin/env python3
"""HTTP server that accepts POST /infer and responds after a delay > gateway TASK_TIMEOUT.
Used only when explicitly enabled: USE_SLOW_INFER_FALLBACK=1 or 103 script --fallback.
Default 103 path uses real backend with INFERENCE_TIMEOUT_SEC=1 for task_timeout;
this server is for no-GPU environments only. Proof/report must label RUN_MODE=slow_infer_fallback."""
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/infer":
            time.sleep(self.server.delay_sec)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        self.wfile.write(b"")
    def log_message(self, *args): pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    delay_sec = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
    s = HTTPServer(("127.0.0.1", port), Handler)
    s.delay_sec = delay_sec
    if port == 0:
        print(s.socket.getsockname()[1], flush=True)
    s.serve_forever()
