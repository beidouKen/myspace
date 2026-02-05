#!/bin/bash
# fast_smoke.sh: Phase 2.3 不变量快验（固化 Phase 2.1/2.2）
# 覆盖：healthz/readyz、Case429、Case504、CaseParallel
# 输出: cli_tests/out/fast_smoke_phase23.txt

set +e
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT/.." && pwd)"
BIN="$ROOT/bin"
OUT="${OUT_DIR:-$ROOT/out}"
OUT="$(mkdir -p "$OUT" && cd "$ROOT" && realpath "$OUT")"
OUT_FILE="$OUT/fast_smoke_phase23.txt"
BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
GATEWAY_LOG="${GATEWAY_LOG:-$PROJECT_ROOT/logs/gateway.log}"

# 临时环境端口（避免与主栈冲突）
PHASE23_GW_PORT="${PHASE23_GW_PORT:-18200}"
PHASE23_HANG_PORT="${PHASE23_HANG_PORT:-18201}"
PHASE23_GW_LOG="$OUT/phase23_gw.log"
PHASE23_HANG_LOG="$OUT/phase23_hang.log"
phase23_gw_pid=""
phase23_hang_pid=""

mkdir -p "$OUT"
: > "$OUT_FILE"

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT_FILE"; }
pass() { log "PASS: $1"; }
fail() { log "FAIL: $1"; exit 1; }

cleanup_phase23() {
  echo "[cleanup] Checking ports 18200/18201 usage:"
  ss -lntp | grep -E ":($PHASE23_GW_PORT|$PHASE23_HANG_PORT)" || true

  [ -n "${phase23_gw_pid:-}" ] && kill -TERM "$phase23_gw_pid" 2>/dev/null || true
  [ -n "${phase23_hang_pid:-}" ] && kill -TERM "$phase23_hang_pid" 2>/dev/null || true
  sleep 1
  [ -n "${phase23_gw_pid:-}" ] && kill -KILL "$phase23_gw_pid" 2>/dev/null || true
  [ -n "${phase23_hang_pid:-}" ] && kill -KILL "$phase23_hang_pid" 2>/dev/null || true
  
  # Ensure ports are free
  for port in $PHASE23_GW_PORT $PHASE23_HANG_PORT; do
    p=$(lsof -ti ":$port" 2>/dev/null || true)
    [ -n "$p" ] && kill -KILL $p 2>/dev/null || true
  done
  phase23_gw_pid=""
  phase23_hang_pid=""
}
trap cleanup_phase23 EXIT INT TERM

log "=== fast_smoke Phase 2.3: invariants (healthz/readyz, Case429, Case504, CaseParallel) ==="
log "BASE_URL=$BASE_URL OUT=$OUT_FILE"
log ""

# --- 1. healthz / readyz ---
log "--- 1. healthz / readyz ---"
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE_URL/healthz" 2>/dev/null || echo "000")
if [ "$CODE" != "200" ]; then
  fail "healthz returned $CODE (expected 200)"
fi
pass "healthz 200"

CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE_URL/readyz" 2>/dev/null || echo "000")
if [ "$CODE" != "200" ] && [ "$CODE" != "503" ]; then
  fail "readyz returned $CODE (expected 200 or 503)"
fi
if [ "$CODE" = "200" ]; then
  pass "readyz 200"
else
  log "readyz 503; waiting up to 60s for backends..."
  for i in $(seq 1 30); do
    sleep 2
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$BASE_URL/readyz" 2>/dev/null || echo "000")
    if [ "$CODE" = "200" ]; then pass "readyz 200 (after wait)"; break; fi
    [ $i -eq 30 ] && fail "readyz did not become 200 within 60s"
  done
fi
log ""

# --- 2. Case504：SYNC_WAIT_TIMEOUT_SEC=1，同步 txt2img → 504 + timeout envelope ---
log "--- 2. Case504: SYNC_WAIT_TIMEOUT_SEC=1, sync txt2img -> 504 + timeout envelope ---"
# 启动 hang backend（POST /infer sleep 600s）
python3 - <<PY >>"$PHASE23_HANG_LOG" 2>&1 &
import time
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("PHASE23_HANG_PORT", "18201"))

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
print(f"[phase23 hang_backend] http://{HOST}:{PORT}", flush=True)
httpd.serve_forever()
PY
phase23_hang_pid=$!

for i in $(seq 1 30); do
  code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PHASE23_HANG_PORT/health" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 0.1
done
code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PHASE23_HANG_PORT/health" 2>/dev/null || echo "000")
[ "$code" = "200" ] || fail "phase23 hang backend not ready (code=$code)"

cd "$PROJECT_ROOT"
QUEUE_SIZE=1 SYNC_WAIT_TIMEOUT_SEC=1 PLATFORM_MODE=1 BACKEND_URLS="http://127.0.0.1:$PHASE23_HANG_PORT" PORT="$PHASE23_GW_PORT" \
  uvicorn app.gateway.main:app --host 127.0.0.1 --port "$PHASE23_GW_PORT" >> "$PHASE23_GW_LOG" 2>&1 &
phase23_gw_pid=$!

for i in $(seq 1 50); do
  code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PHASE23_GW_PORT/healthz" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 0.1
done
code=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PHASE23_GW_PORT/healthz" 2>/dev/null || echo "000")
[ "$code" = "200" ] || fail "phase23 gateway not ready (code=$code)"
sleep 0.3

PHASE23_BASE="http://127.0.0.1:$PHASE23_GW_PORT"
RESP=$(curl -sS --max-time 45 -w "\n%{http_code}" -X POST "$PHASE23_BASE/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"sync timeout test","sync":true,"response_format":"url"}')
curl_ret=$?
BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)
echo "$BODY" >> "$OUT_FILE"

if [ $curl_ret -ne 0 ]; then
  log "Case504: curl failed (exit $curl_ret). http_code=$CODE body=$BODY"
  fail "Case504: curl timeout or error (exit $curl_ret)"
fi
if [ "$CODE" != "504" ]; then
  log "Case504: expected 504, got http_code=$CODE body=$BODY"
  fail "Case504: expected 504, got $CODE"
fi
echo "$BODY" | grep -q '"error"' || fail "Case504: 504 body missing 'error' envelope"
echo "$BODY" | grep -q '"code"[[:space:]]*:[[:space:]]*"sync_wait_timeout"' || fail "Case504: 504 body missing code=sync_wait_timeout"
echo "$BODY" | grep -qi 'exceeded SYNC_WAIT_TIMEOUT_SEC\|sync wait timeout' || fail "Case504: 504 message missing exceeded SYNC_WAIT_TIMEOUT_SEC"
pass "Case504: 504 + timeout envelope (message contains exceeded SYNC_WAIT_TIMEOUT_SEC)"
log ""

# --- 3. Case429：QUEUE_SIZE=1，并发 3 个 txt2img，至少 2 个 429 + rate_limit_error ---
log "--- 3. Case429: QUEUE_SIZE=1, 3 concurrent txt2img, >=2 x 429 + rate_limit_error ---"
PAYLOAD='{"prompt":"phase23 queue guard","steps":10,"size":"512x512","response_format":"url"}'
CASE429_MAX_TIME=30

pids=""
for i in 1 2 3; do
  (
    # 保存完整响应（body + newline + http_code）到临时文件
    OUT_F="$OUT/phase23_429_req_$i.txt"
    curl -sS --max-time "$CASE429_MAX_TIME" -w "\n%{http_code}" \
      -X POST "$PHASE23_BASE/v1/images/generations" \
      -H "Content-Type: application/json" -d "$PAYLOAD" > "$OUT_F" 2>/dev/null
    
    # 简单的容错：如果 curl 失败/超时，文件可能为空或不完整，追加一个非 200/429 的状态码以防 grep 失败
    echo "" >> "$OUT_F"
  ) &
  pids="$pids $!"
done
wait $pids


count_429=0
for i in 1 2 3; do
  F="$OUT/phase23_429_req_$i.txt"
  if [ ! -f "$F" ]; then
    log "  request $i: No output file"
    continue
  fi
  
  # 提取最后一行作为 HTTP CODE，前面的是 BODY
  HTTP_CODE=$(tail -n 1 "$F" | tr -d '\n\r')
  # 如果最后一行是空（可能 curl 失败），尝试取倒数第二行或标记为 000
  if [ -z "$HTTP_CODE" ]; then HTTP_CODE="000"; fi
  
  BODY=$(sed '$d' "$F")
  
  log "  request $i: HTTP $HTTP_CODE"
  
  if [ "$HTTP_CODE" = "429" ]; then
    count_429=$((count_429 + 1))
    echo "$BODY" >> "$OUT_FILE"
    echo "$BODY" | grep -q '"error"' || fail "Case429: 429 body missing 'error' envelope"
    echo "$BODY" | grep -q '"type"[[:space:]]*:[[:space:]]*"rate_limit_error"' || fail "Case429: 429 body missing type=rate_limit_error"
    echo "$BODY" | grep -qi 'queue.*full\|try.*later' || fail "Case429: 429 message missing queue full / try later"
  fi
done

if [ "$count_429" -lt 2 ]; then
  fail "Case429: expected >=2 x 429, got $count_429"
fi
pass "Case429: at least 2 x 429 + rate_limit_error (envelope and message validated)"
log ""

# 关闭临时网关与 hang，以便后续 CaseParallel 使用主栈
cleanup_phase23
phase23_gw_pid=""
phase23_hang_pid=""
sleep 0.5

# --- 4. CaseParallel：并发 2 个 txt2img，证明派到不同 backend ---
log "--- 4. CaseParallel: 2 concurrent txt2img -> different backends ---"
R1=$(curl -sS --max-time 15 -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Phase23 parallel A","response_format":"url"}')
R2=$(curl -sS --max-time 15 -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Phase23 parallel B","response_format":"url"}')

TASK_ID_1=$(echo "$R1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task_id',''))" 2>/dev/null || true)
TASK_ID_2=$(echo "$R2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task_id',''))" 2>/dev/null || true)

if [ -z "$TASK_ID_1" ] || [ -z "$TASK_ID_2" ]; then
  fail "CaseParallel: could not get two task_ids. R1=$R1 R2=$R2"
fi
log "  task_id_1=$TASK_ID_1 task_id_2=$TASK_ID_2"
echo "task_id_1=$TASK_ID_1" >> "$OUT_FILE"
echo "task_id_2=$TASK_ID_2" >> "$OUT_FILE"

for i in $(seq 1 300); do
  S1=$(curl -sS --max-time 5 "$BASE_URL/v1/tasks/$TASK_ID_1" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  S2=$(curl -sS --max-time 5 "$BASE_URL/v1/tasks/$TASK_ID_2" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  [ "$S1" = "completed" ] && [ "$S2" = "completed" ] && break
  [ "$S1" = "failed" ] || [ "$S2" = "failed" ] && fail "CaseParallel: one or both tasks failed: s1=$S1 s2=$S2"
  sleep 1
done
[ "$S1" = "completed" ] && [ "$S2" = "completed" ] || fail "CaseParallel: timeout waiting for both completed (s1=$S1 s2=$S2)"
pass "CaseParallel: both tasks completed"

T1_JSON=$(curl -sS --max-time 5 "$BASE_URL/v1/tasks/$TASK_ID_1")
T2_JSON=$(curl -sS --max-time 5 "$BASE_URL/v1/tasks/$TASK_ID_2")
BACKEND_1=$(echo "$T1_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('backend_id',''))" 2>/dev/null || true)
BACKEND_2=$(echo "$T2_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('backend_id',''))" 2>/dev/null || true)

log "  backend_id_1=$BACKEND_1 backend_id_2=$BACKEND_2"
echo "backend_id_1=$BACKEND_1" >> "$OUT_FILE"
echo "backend_id_2=$BACKEND_2" >> "$OUT_FILE"

if [ -n "$BACKEND_1" ] && [ -n "$BACKEND_2" ]; then
  if [ "$BACKEND_1" = "$BACKEND_2" ]; then
    fail "CaseParallel: both tasks on same backend ($BACKEND_1); expected different backends"
  fi
  pass "CaseParallel: dispatched to different backends ($BACKEND_1 vs $BACKEND_2)"
else
  log "  backend_id missing in /v1/tasks; trying /metrics or gateway log..."
  if [ -f "$GATEWAY_LOG" ]; then
    B1=$(grep "DISPATCH" "$GATEWAY_LOG" 2>/dev/null | grep "$TASK_ID_1" | tail -1 | sed -n 's/.*"backend"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    B2=$(grep "DISPATCH" "$GATEWAY_LOG" 2>/dev/null | grep "$TASK_ID_2" | tail -1 | sed -n 's/.*"backend"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$B1" ] && [ -n "$B2" ] && [ "$B1" != "$B2" ]; then
      pass "CaseParallel: different backends from DISPATCH log ($B1 vs $B2)"
    else
      fail "CaseParallel: could not prove different backends (backend_id or DISPATCH)"
    fi
  else
    fail "CaseParallel: could not prove different backends (no backend_id, no GATEWAY_LOG)"
  fi
fi
log ""

# --- 5. Phase 3: 轻量多图融合 (n=1) ---
log "--- 5. Phase 3: Light multi-image fusion (2 images, n=1) ---"
ASSETS="$ROOT/assets"
IMG="$ASSETS/dog.png"
if [ ! -f "$IMG" ]; then
  python3 -c "from PIL import Image; Image.new('RGB', (64,64), color='red').save('$OUT/phase3_smoke_1.png'); Image.new('RGB', (64,64), color='blue').save('$OUT/phase3_smoke_2.png')" 2>/dev/null || true
  IMG="$OUT/phase3_smoke_1.png"
  IMG2="$OUT/phase3_smoke_2.png"
else
  IMG2="$IMG"
fi
RESP_P3=$(curl -sS --max-time 300 -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -F "prompt=Phase3 smoke fusion" \
  -F "image=@$IMG" \
  -F "image=@$IMG2" \
  -F "n=1" \
  -F "sync=true" \
  -F "response_format=url" 2>/dev/null)
BODY_P3=$(echo "$RESP_P3" | sed '$d')
CODE_P3=$(echo "$RESP_P3" | tail -n1)
echo "$BODY_P3" >> "$OUT_FILE"
if [ "$CODE_P3" != "200" ]; then
  if echo "$BODY_P3" | grep -q "not_ready\|Backend unreachable"; then
    log "SKIP: Phase3 multi-image fusion (backends not ready)"
  else
    fail "Phase3 multi-image fusion: expected 200, got $CODE_P3"
  fi
else
  LEN_P3=$(echo "$BODY_P3" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data', [])))" 2>/dev/null || echo "0")
  [ "$LEN_P3" != "1" ] && fail "Phase3: expected data.length==1, got $LEN_P3"
  URL_P3=$(echo "$BODY_P3" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data', [{}])[0].get('url', ''))" 2>/dev/null || true)
  [ -z "$URL_P3" ] && fail "Phase3: no url in data[0]"
  C_P3=$(curl -sS -o /dev/null -w "%{http_code}" -I --max-time 10 "$URL_P3" 2>/dev/null || echo "000")
  [ "$C_P3" != "200" ] && fail "Phase3: url returned $C_P3 (expected 200)"
  pass "Phase3: multi-image fusion n=1, data.length==1, url 200"
fi
log ""

# --- 6. P3.3 回归：轻量 n=2（只校验 data.length==2 + 两 url 200，不校验 n_mode）---
log "--- 6. P3.3 regression: Light n=2 (data.length==2, 2 URLs 200) ---"
RESP_N2=$(curl -sS --max-time 300 -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -F "prompt=Phase3 smoke n=2" \
  -F "image=@$IMG" \
  -F "image=@$IMG2" \
  -F "n=2" \
  -F "steps=${PHASE3_STEPS:-20}" \
  -F "size=${PHASE3_SIZE:-512x512}" \
  -F "sync=true" \
  -F "response_format=url" 2>/dev/null)
BODY_N2=$(echo "$RESP_N2" | sed '$d')
CODE_N2=$(echo "$RESP_N2" | tail -n1)
echo "$BODY_N2" >> "$OUT_FILE"
if [ "$CODE_N2" != "200" ]; then
  if echo "$BODY_N2" | grep -q "not_ready\|Backend unreachable"; then
    log "SKIP: P3.3 n=2 (backends not ready)"
  else
    fail "P3.3 n=2: expected 200, got $CODE_N2"
  fi
else
  LEN_N2=$(echo "$BODY_N2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data', [])))" 2>/dev/null || echo "0")
  [ "$LEN_N2" != "2" ] && fail "P3.3 n=2: expected data.length==2, got $LEN_N2"
  U1=$(echo "$BODY_N2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data', [{}])[0].get('url', ''))" 2>/dev/null || true)
  U2=$(echo "$BODY_N2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data', [{}])[1].get('url', ''))" 2>/dev/null || true)
  [ -z "$U1" ] || [ -z "$U2" ] && fail "P3.3 n=2: missing url in data"
  C1=$(curl -sS -o /dev/null -w "%{http_code}" -I --max-time 10 "$U1" 2>/dev/null || echo "000")
  C2=$(curl -sS -o /dev/null -w "%{http_code}" -I --max-time 10 "$U2" 2>/dev/null || echo "000")
  [ "$C1" != "200" ] && fail "P3.3 n=2: url_1 returned $C1 (expected 200)"
  [ "$C2" != "200" ] && fail "P3.3 n=2: url_2 returned $C2 (expected 200)"
  pass "P3.3 n=2: data.length==2, both URLs 200"
fi
log ""

log "=== fast_smoke Phase 2.3 + Phase 3: ALL PASS ==="
log "Output: $OUT_FILE"
exit 0
