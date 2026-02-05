#!/bin/bash
# phase2_queue_guard.sh: Phase 2.1 队列语义验收
# Case201: QUEUE_SIZE=1 并发打多请求 → 至少 2 个 429，校验 OpenAI envelope
# Case202: SYNC_WAIT_TIMEOUT_SEC=1 同步 txt2img → 504，校验 envelope
# 输出: cli_tests/out/phase2_queue_guard.txt

set +e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT="$(mkdir -p "$OUT" && cd "$ROOT" && realpath "$OUT")"
OUT_FILE="$OUT/phase2_queue_guard.txt"
GW_PORT="${GW_PORT:-18010}"
HANG_PORT="${HANG_PORT:-18011}"
GW_LOG="$OUT/phase2_gw.log"
HANG_LOG="$OUT/phase2_hang.log"

gw_pid=""
hang_pid=""
rm -f "$OUT_FILE" "$GW_LOG" "$HANG_LOG" "$OUT"/phase2_201_*.txt "$OUT"/phase2_202_*.txt 2>/dev/null

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT_FILE"; }
pass() { echo "PASS: $*" | tee -a "$OUT_FILE"; }
fail() { echo "FAIL: $*" | tee -a "$OUT_FILE"; exit 1; }

cleanup() {
  [ -n "${gw_pid:-}" ] && kill "$gw_pid" 2>/dev/null || true
  [ -n "${hang_pid:-}" ] && kill "$hang_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "=== Phase 2.1 queue guard: Case201 (429) + Case202 (504) ==="
log "GW_PORT=$GW_PORT HANG_PORT=$HANG_PORT OUT=$OUT_FILE"
log ""

export HANG_PORT
# ---------- 启动 hang backend（POST /infer sleep 600s）----------
python3 - <<PY >>"$HANG_LOG" 2>&1 &
import time
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("HANG_PORT", "18011"))

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/health") or self.path.startswith("/healthz"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok","model_loaded":true}')
            return
        self.send_response(404); self.end_headers()

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length","0"))
            if length > 0:
                _ = self.rfile.read(length)
        except Exception:
            pass
        if self.path.startswith("/infer"):
            time.sleep(600)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        self.send_response(404); self.end_headers()

    def log_message(self, fmt, *args):
        return

httpd = HTTPServer((HOST, PORT), Handler)
print(f"[phase2 hang_backend] http://{HOST}:{PORT}", flush=True)
httpd.serve_forever()
PY
hang_pid=$!

for i in $(seq 1 30); do
  code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$HANG_PORT/health" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 0.1
done
code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$HANG_PORT/health" 2>/dev/null || echo "000")
[ "$code" = "200" ] || fail "hang backend not ready (code=$code)"
log "hang backend ready: http://127.0.0.1:$HANG_PORT (pid=$hang_pid)"

# ---------- 启动临时网关 QUEUE_SIZE=1 SYNC_WAIT_TIMEOUT_SEC=1 ----------
cd "$ROOT"
QUEUE_SIZE=1 SYNC_WAIT_TIMEOUT_SEC=1 PLATFORM_MODE=1 BACKEND_URLS="http://127.0.0.1:$HANG_PORT" PORT="$GW_PORT" \
  uvicorn app.gateway.main:app --host 127.0.0.1 --port "$GW_PORT" >> "$GW_LOG" 2>&1 &
gw_pid=$!

for i in $(seq 1 50); do
  code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GW_PORT/healthz" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 0.1
done
code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GW_PORT/healthz" 2>/dev/null || echo "000")
[ "$code" = "200" ] || fail "gateway not ready (code=$code)"
log "gateway ready: http://127.0.0.1:$GW_PORT (pid=$gw_pid) QUEUE_SIZE=1 SYNC_WAIT_TIMEOUT_SEC=1"
sleep 0.3

BASE="http://127.0.0.1:$GW_PORT"
PAYLOAD='{"prompt":"phase2 queue guard","steps":10,"size":"512x512","response_format":"url"}'

# ---------- Case202 先跑：SYNC_WAIT_TIMEOUT_SEC=1，同步 txt2img → 504（此时队列空，worker 占住后 sync 等待超时）----------
log ""
log "--- Case202: SYNC_WAIT_TIMEOUT_SEC=1, sync txt2img -> 504 ---"
RESP=$(curl -sS --max-time 10 -w "\n%{http_code}" -X POST "$BASE/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"sync timeout test","sync":true,"response_format":"url"}')
BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)

log "  HTTP code: $CODE"
echo "$BODY" >> "$OUT_FILE"

if [ "$CODE" != "504" ]; then
  fail "Case202: expected 504, got $CODE"
fi
echo "$BODY" | grep -q '"error"' || fail "Case202: 504 body missing 'error'"
echo "$BODY" | grep -q '"code"[[:space:]]*:[[:space:]]*"sync_wait_timeout"' || fail "Case202: 504 body missing code=sync_wait_timeout"
echo "$BODY" | grep -qi 'exceeded SYNC_WAIT_TIMEOUT_SEC\|sync wait timeout' || fail "Case202: 504 message missing exceeded SYNC_WAIT_TIMEOUT_SEC / sync wait timeout"

pass "Case202: 504 with OpenAI envelope (sync_wait_timeout, message exceeded SYNC_WAIT_TIMEOUT_SEC)"

# ---------- Case201: 并发 4 个 txt2img，至少 2 个 429 ----------
log ""
log "--- Case201: QUEUE_SIZE=1, 4 concurrent txt2img, expect >=2 x 429 ---"
for i in 1 2 3 4; do
  curl -sS --max-time 5 -o "$OUT/phase2_201_resp_$i.txt" -w "%{http_code}" \
    -X POST "$BASE/v1/images/generations" -H "Content-Type: application/json" -d "$PAYLOAD" \
    > "$OUT/phase2_201_code_$i.txt" 2>/dev/null &
done
wait

count_429=0
for i in 1 2 3 4; do
  c=$(cat "$OUT/phase2_201_code_$i.txt" 2>/dev/null | tr -d '\n\r')
  if [ "$c" = "429" ]; then
    count_429=$((count_429 + 1))
    log "  request $i: HTTP 429"
    body=$(cat "$OUT/phase2_201_resp_$i.txt" 2>/dev/null)
    echo "$body" >> "$OUT_FILE"
    echo "$body" | grep -q '"error"' || fail "Case201: 429 body missing 'error'"
    echo "$body" | grep -q '"type"[[:space:]]*:[[:space:]]*"rate_limit_error"' || fail "Case201: 429 body missing type=rate_limit_error"
    echo "$body" | grep -q '"code"[[:space:]]*:[[:space:]]*"queue_full"' || fail "Case201: 429 body missing code=queue_full"
    echo "$body" | grep -qi 'queue.*full\|try.*later' || fail "Case201: 429 message missing queue is full / try later"
  else
    log "  request $i: HTTP $c"
  fi
done

if [ "$count_429" -lt 2 ]; then
  fail "Case201: expected >=2 x 429, got $count_429"
fi
pass "Case201: at least 2 x 429 with OpenAI envelope (rate_limit_error, queue_full, message queue is full / try later)"
log ""
log "=== Phase 2.1 phase2_queue_guard.sh: ALL PASS ==="
log "Output: $OUT_FILE"
exit 0
