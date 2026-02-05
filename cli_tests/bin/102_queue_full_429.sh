#!/bin/bash
# 102_queue_full_429.sh: 交付级“确定性触发 429 queue_full”
# 设计：启动临时网关(QUEUE_SIZE=1) + 启动 hang backend(POST /infer hang 600s)
#      连续发 3 个（默认 async）请求：第1占 worker，第2占队列，第3必 429
# 约束：禁止宽杀，仅 kill 记录的 gw_pid/hang_pid；curl 永不长等待

set +e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
mkdir -p "$OUT_DIR"

PROOF="$OUT_DIR/102_queue_full_429_proof.txt"
GW_PORT="${GW_PORT:-18001}"
HANG_PORT="${HANG_PORT:-18002}"
GW_LOG="$OUT_DIR/102_gw.log"
HANG_LOG="$OUT_DIR/102_hang_backend.log"

gw_pid=""
hang_pid=""

rm -f "$PROOF" "$GW_LOG" "$HANG_LOG" \
  "$OUT_DIR"/102_code_*.txt "$OUT_DIR"/102_resp_*.json "$OUT_DIR"/102_429_body.json "$OUT_DIR"/102_429_code.txt \
  "$OUT_DIR"/102_phase2_fill_*.txt 2>/dev/null

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$PROOF"; }
pass() { echo "PASS: $*" | tee -a "$PROOF"; }
fail() { echo "FAIL: $*" | tee -a "$PROOF"; exit 1; }

cleanup() {
  # 只杀本脚本起的进程
  [ -n "${gw_pid:-}" ] && kill "$gw_pid" 2>/dev/null || true
  [ -n "${hang_pid:-}" ] && kill "$hang_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "102_queue_full_429.sh: deterministic 429 queue_full (temp gateway QUEUE_SIZE=1 + hang backend)"
log "ENV: GW_PORT=$GW_PORT HANG_PORT=$HANG_PORT BACKEND_URLS=${BACKEND_URLS:-http://127.0.0.1:$HANG_PORT}"

# -------------------------
# 0) 启动 hang backend（HTTP server: POST /infer -> sleep 600s）
# -------------------------
python3 - <<PY >>"$HANG_LOG" 2>&1 &
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = int("${HANG_PORT}")

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
        # 读掉 body（避免客户端阻塞）
        try:
            length = int(self.headers.get("Content-Length","0"))
            if length > 0:
                _ = self.rfile.read(length)
        except Exception:
            pass

        if self.path.startswith("/infer"):
            # 故意 hang 很久，模拟后端卡住（占住 worker）
            time.sleep(600)
            # 即便醒来，也给个最小响应（理论上不会用到）
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return

        self.send_response(404); self.end_headers()

    def log_message(self, fmt, *args):
        # 安静一点
        return

httpd = HTTPServer((HOST, PORT), Handler)
print(f"[hang_backend] listening on http://{HOST}:{PORT}", flush=True)
httpd.serve_forever()
PY
hang_pid=$!

# 等 hang backend ready（最多 3s）
for i in $(seq 1 30); do
  code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$HANG_PORT/healthz" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 0.1
done
code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$HANG_PORT/healthz" 2>/dev/null || echo "000")
if [ "$code" != "200" ]; then
  tail -80 "$HANG_LOG" 2>/dev/null | tee -a "$PROOF"
  fail "hang backend not ready (healthz=$code)"
fi
log "hang backend ready: http://127.0.0.1:$HANG_PORT (pid=$hang_pid)"

# -------------------------
# 1) 启动临时网关（QUEUE_SIZE=1, PLATFORM_MODE=1, BACKEND_URLS -> hang backend）
# -------------------------
cd "$ROOT"

QUEUE_SIZE=1 PLATFORM_MODE=1 BACKEND_URLS="http://127.0.0.1:$HANG_PORT" PORT="$GW_PORT" \
  uvicorn app.gateway.main:app --host 127.0.0.1 --port "$GW_PORT" >> "$GW_LOG" 2>&1 &
gw_pid=$!

# 等 gateway ready（最多 5s）
for i in $(seq 1 50); do
  code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GW_PORT/healthz" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 0.1
done
code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GW_PORT/healthz" 2>/dev/null || echo "000")
if [ "$code" != "200" ]; then
  tail -120 "$GW_LOG" 2>/dev/null | tee -a "$PROOF"
  fail "temp gateway not ready (healthz=$code)"
fi
log "temp gateway ready: http://127.0.0.1:$GW_PORT (pid=$gw_pid)"
sleep 0.5

BASE="http://127.0.0.1:$GW_PORT"
# 不传 sync=true（默认 PLATFORM_MODE=1 => async-first）；只拿状态码用 -o /dev/null，避免 200 响应体拖住 wait
PAYLOAD='{"prompt":"deterministic 429 test","steps":30,"size":"1024x1024","response_format":"url"}'

# -------------------------
# 两阶段触发 429 并抓 body（15s 内必退）
# Phase 1：只拿状态码，不抓 body（避免 200 响应体拖住 wait）。顺序发 3 个请求，max-time 3，第 3 个必 429；最多 3 轮
# Phase 2：若 Phase 1 出现 429，立刻单独再发 1 次抓 body；必须 429 否则 FAIL
# 注：顺序请求可保证 15s 内结束且不挂住；并发 3 curl + wait 在本环境易得 000 导致脚本超时
# -------------------------
GOT_429=0
for round in 1 2 3; do
  rm -f "$OUT_DIR"/102_code_*.txt "$OUT_DIR"/102_429_body.json "$OUT_DIR"/102_429_code.txt 2>/dev/null

  # 顺序发 3 个，仅状态码 -o /dev/null
  for i in 1 2 3; do
    curl -sS --max-time 3 -o /dev/null -w "%{http_code}" \
      -X POST "$BASE/v1/images/generations" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" > "$OUT_DIR/102_code_$i.txt" 2>/dev/null
  done

  for i in 1 2 3; do
    [ -f "$OUT_DIR/102_code_$i.txt" ] || continue
    c="$(cat "$OUT_DIR/102_code_$i.txt" 2>/dev/null | tr -d '\n\r')"
    if [ "$c" = "429" ]; then
      GOT_429=1
      break
    fi
  done

  if [ "$GOT_429" -eq 1 ]; then
    # Phase 2：立刻单独再发 1 次，抓 429 body
    curl -sS --max-time 3 -o "$OUT_DIR/102_429_body.json" -w "%{http_code}" \
      -X POST "$BASE/v1/images/generations" -H "Content-Type: application/json" \
      -d "$PAYLOAD" > "$OUT_DIR/102_429_code.txt" 2>/dev/null
    phase2_code="$(cat "$OUT_DIR/102_429_code.txt" 2>/dev/null | tr -d '\n\r')"
    if [ "$phase2_code" = "429" ]; then
      break
    fi
    GOT_429=0
  fi
  sleep 0.15
done

if [ "$GOT_429" -ne 1 ]; then
  log "429 not triggered (Phase1). 102_code_*.txt contents:"
  for i in 1 2 3; do
    [ -f "$OUT_DIR/102_code_$i.txt" ] && log "  102_code_$i.txt: $(cat "$OUT_DIR/102_code_$i.txt" 2>/dev/null | tr -d '\n\r')"
  done
  log "--- 102_gw.log tail ---"
  tail -120 "$GW_LOG" 2>/dev/null | tee -a "$PROOF"
  fail "Could not trigger 429 queue_full (Phase1 no 429)"
fi

phase2_code="$(cat "$OUT_DIR/102_429_code.txt" 2>/dev/null | tr -d '\n\r')"
if [ "$phase2_code" != "429" ]; then
  log "Phase2 request did not return 429 (got $phase2_code). 102_429_code.txt / body:"
  log "  102_429_code.txt: $phase2_code"
  [ -f "$OUT_DIR/102_429_body.json" ] && log "  102_429_body.json: $(cat "$OUT_DIR/102_429_body.json" 2>/dev/null)"
  fail "Phase2 must return 429 for proof"
fi

BODY_FILE_429="$OUT_DIR/102_429_body.json"
BODY="$(cat "$BODY_FILE_429" 2>/dev/null)"

# 写 proof
{
  echo ""
  echo "=== 102 real 429 queue_full (status + body) ==="
  echo "HTTP_STATUS: 429"
  echo "BODY:"
  echo "$BODY"
  echo ""
  echo "ENV: QUEUE_SIZE=1 PLATFORM_MODE=1 GW_PORT=$GW_PORT HANG_PORT=$HANG_PORT"
} >> "$PROOF"

# 校验 envelope: type=rate_limit_error, code=queue_full, param=null
echo "$BODY" | grep -q '"type"[[:space:]]*:[[:space:]]*"rate_limit_error"' || fail "429 body missing type=rate_limit_error: $BODY"
echo "$BODY" | grep -q '"code"[[:space:]]*:[[:space:]]*"queue_full"' || fail "429 body missing code=queue_full: $BODY"
echo "$BODY" | grep -q '"param"[[:space:]]*:[[:space:]]*null' || fail "429 body missing param=null: $BODY"

pass "429 body has OpenAI envelope (type=rate_limit_error, code=queue_full, param=null)"
pass "102_queue_full_429.sh completed successfully (deterministic 429 captured)."
exit 0
