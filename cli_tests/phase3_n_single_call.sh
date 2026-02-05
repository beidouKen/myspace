#!/bin/bash
# phase3_n_single_call.sh: P3.3 验收 — single_call 生效 + 回退路径可用
# Case301: 主栈 img2img n=2，断言 n_mode="single_call"、data.length==2、两 url 200
# Case302: 临时后端 FORCE_FALLBACK_LOOP=1，同样请求，断言 n_mode="fallback_loop"、data.length==2
# 输出: cli_tests/out/phase3_n_single_call.txt

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$ROOT"
OUT="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT="$(mkdir -p "$OUT" && cd "$ROOT" && realpath "$OUT")"
OUT_FILE="$OUT/phase3_n_single_call.txt"
BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
BACKEND_LOGS="${BACKEND_LOGS:-$PROJECT_ROOT/logs}"
PHASE3_STEPS="${PHASE3_STEPS:-20}"
PHASE3_SIZE="${PHASE3_SIZE:-512x512}"
ASSETS="$ROOT/cli_tests/assets"

# Case302 临时后端/网关
P33_BACKEND_PORT="${P33_BACKEND_PORT:-18001}"
P33_GW_PORT="${P33_GW_PORT:-18000}"
P33_BACKEND_LOG="$OUT/phase3_p33_backend.log"
P33_GW_LOG="$OUT/phase3_p33_gw.log"
p33_backend_pid=""
p33_gw_pid=""

rm -f "$OUT_FILE"
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT_FILE"; }
pass() { echo "PASS: $*" | tee -a "$OUT_FILE"; }
fail() { echo "FAIL: $*" | tee -a "$OUT_FILE"; exit 1; }

cleanup_case302() {
  [ -n "${p33_gw_pid:-}" ] && kill "$p33_gw_pid" 2>/dev/null || true
  [ -n "${p33_backend_pid:-}" ] && kill "$p33_backend_pid" 2>/dev/null || true
}
trap cleanup_case302 EXIT INT TERM

log "=== Phase 3.3: n>1 single_call + fallback (Case301 single_call, Case302 fallback_loop) ==="
log "BASE_URL=$BASE_URL BACKEND_LOGS=$BACKEND_LOGS OUT=$OUT_FILE"
log ""

# 准备 2 张图
IMG="$ASSETS/dog.png"
if [ ! -f "$IMG" ]; then
  python3 -c "
from PIL import Image
Image.new('RGB', (64,64), color='red').save('$OUT/phase3_n1.png')
Image.new('RGB', (64,64), color='blue').save('$OUT/phase3_n2.png')
" 2>/dev/null || true
  IMG1="$OUT/phase3_n1.png"
  IMG2="$OUT/phase3_n2.png"
else
  IMG1="$IMG"
  IMG2="$IMG"
fi

# ---------- Case301: 期望 single_call ----------
log "--- Case301: img2img 2 images n=2 (light params), expect n_mode=single_call ---"
RESP=$(curl -sS --max-time 300 -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -F "prompt=P3.3 Case301 fusion" \
  -F "image=@$IMG1" \
  -F "image=@$IMG2" \
  -F "n=2" \
  -F "steps=$PHASE3_STEPS" \
  -F "size=$PHASE3_SIZE" \
  -F "sync=true" \
  -F "response_format=url")
BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)
echo "$BODY" >> "$OUT_FILE"

if [ "$CODE" != "200" ]; then
  fail "Case301: Expected HTTP 200, got $CODE. Body: $BODY"
fi
pass "Case301: HTTP 200"

LEN=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data', [])))" 2>/dev/null || echo "0")
if [ "$LEN" != "2" ]; then
  fail "Case301: Expected data.length==2, got $LEN"
fi
pass "Case301: data.length==2"

URL_1=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
data = d.get('data', [])
print(data[0].get('url', '') if len(data) > 0 else '')
" 2>/dev/null)
URL_2=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
data = d.get('data', [])
print(data[1].get('url', '') if len(data) > 1 else '')
" 2>/dev/null)
[ -z "$URL_1" ] || [ -z "$URL_2" ] && fail "Case301: Missing url in data[0] or data[1]"
CODE_1=$(curl -sS -o /dev/null -w "%{http_code}" -I --max-time 10 "$URL_1" 2>/dev/null || echo "000")
CODE_2=$(curl -sS -o /dev/null -w "%{http_code}" -I --max-time 10 "$URL_2" 2>/dev/null || echo "000")
[ "$CODE_1" != "200" ] && fail "Case301: url_1 returned $CODE_1 (expected 200)"
[ "$CODE_2" != "200" ] && fail "Case301: url_2 returned $CODE_2 (expected 200)"
pass "Case301: Both output URLs return 200"

# task_id 从 output url 提取: .../outputs/<task_id>_0.png
TASK_ID_301=$(echo "$URL_1" | python3 -c "
import sys
url = sys.stdin.read().strip()
# .../outputs/xxx_0.png -> xxx
if '/outputs/' in url:
    part = url.split('/outputs/')[-1]
    if part.endswith('_0.png'):
        print(part[:-6])
    else:
        print('')
else:
    print('')
" 2>/dev/null || echo "")

if [ -z "$TASK_ID_301" ]; then
  log "Case301: Could not extract task_id from url ($URL_1), will grep backend logs by n_mode only for recent INFERENCE_LOG"
else
  log "Debug: extracted TASK_ID_301=$TASK_ID_301"
fi
sleep 2

# 从后端日志中找本次 task_id 的 INFERENCE_LOG，断言 n_mode="single_call"
FOUND_SINGLE=0
for bl in "$BACKEND_LOGS"/backend_*.log; do
  [ -f "$bl" ] || continue
  if [ -n "$TASK_ID_301" ]; then
    line=$(grep "INFERENCE_LOG" "$bl" 2>/dev/null | grep "$TASK_ID_301" | grep '"n_mode".*"single_call"' | tail -1)
  else
    line=$(grep "INFERENCE_LOG" "$bl" 2>/dev/null | grep '"n_mode".*"single_call"' | tail -1)
  fi
  if [ -n "$line" ]; then
    echo "$line" >> "$OUT_FILE"
    FOUND_SINGLE=1
    break
  fi
done
if [ "$FOUND_SINGLE" -eq 0 ]; then
  for bl in "$BACKEND_LOGS"/backend_*.log; do
    [ -f "$bl" ] || continue
    line=$(grep "INFERENCE_LOG" "$bl" 2>/dev/null | grep '"n_mode".*"single_call"' | tail -1)
    if [ -n "$line" ]; then
      echo "$line" >> "$OUT_FILE"
      FOUND_SINGLE=1
      break
    fi
  done
fi
[ "$FOUND_SINGLE" -eq 0 ] && fail "Case301: No INFERENCE_LOG with n_mode=single_call found in $BACKEND_LOGS/backend_*.log"
pass "Case301: Backend INFERENCE_LOG contains n_mode=single_call"
log ""

# ---------- Case302: FORCE_FALLBACK_LOOP=1，期望 fallback_loop ----------
log "--- Case302: Same request with FORCE_FALLBACK_LOOP=1, expect n_mode=fallback_loop ---"
# 启动临时后端（需 MODEL_DIR/OUTPUTS_DIR 等与主栈一致）
export MODEL_DIR="${MODEL_DIR:-/root/models/zai-org/GLM-Image}"
export OUTPUTS_DIR="${OUTPUTS_DIR:-$PROJECT_ROOT/outputs}"
mkdir -p "$OUTPUTS_DIR"
cd "$PROJECT_ROOT"
FORCE_FALLBACK_LOOP=1 CUDA_VISIBLE_DEVICES=1 uvicorn app.backend.main:app --host 127.0.0.1 --port "$P33_BACKEND_PORT" >> "$P33_BACKEND_LOG" 2>&1 &
p33_backend_pid=$!

log "Waiting for Case302 backend (port $P33_BACKEND_PORT) to be ready (up to 120s)..."
for i in $(seq 1 120); do
  code=$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P33_BACKEND_PORT/health" 2>/dev/null || echo "000")
  [ "$code" = "200" ] && break
  sleep 1
done
code=$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P33_BACKEND_PORT/health" 2>/dev/null || echo "000")
[ "$code" != "200" ] && fail "Case302: Backend on $P33_BACKEND_PORT not ready (code=$code) within 120s"
pass "Case302: Backend ready"

# 启动临时网关
cd "$PROJECT_ROOT"
QUEUE_SIZE=4 TASK_TIMEOUT_SEC=120 SYNC_WAIT_TIMEOUT_SEC=60 BACKEND_URLS="http://127.0.0.1:$P33_BACKEND_PORT" PORT="$P33_GW_PORT" \
  uvicorn app.gateway.main:app --host 127.0.0.1 --port "$P33_GW_PORT" >> "$P33_GW_LOG" 2>&1 &
p33_gw_pid=$!
for i in $(seq 1 30); do
  code=$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P33_GW_PORT/healthz" 2>/dev/null || echo "000")
  [ "$code" = "200" ] && break
  sleep 0.5
done
code=$(curl -sS --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$P33_GW_PORT/healthz" 2>/dev/null || echo "000")
[ "$code" != "200" ] && fail "Case302: Gateway on $P33_GW_PORT not ready (code=$code)"
sleep 0.5

P33_BASE="http://127.0.0.1:$P33_GW_PORT"
RESP2=$(curl -sS --max-time 300 -w "\n%{http_code}" -X POST "$P33_BASE/v1/images/edits" \
  -F "prompt=P3.3 Case302 fusion" \
  -F "image=@$IMG1" \
  -F "image=@$IMG2" \
  -F "n=2" \
  -F "steps=$PHASE3_STEPS" \
  -F "size=$PHASE3_SIZE" \
  -F "sync=true" \
  -F "response_format=url")
BODY2=$(echo "$RESP2" | sed '$d')
CODE2=$(echo "$RESP2" | tail -n1)
echo "$BODY2" >> "$OUT_FILE"

if [ "$CODE2" != "200" ]; then
  fail "Case302: Expected HTTP 200, got $CODE2. Body: $BODY2"
fi
pass "Case302: HTTP 200"

LEN2=$(echo "$BODY2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data', [])))" 2>/dev/null || echo "0")
[ "$LEN2" != "2" ] && fail "Case302: Expected data.length==2, got $LEN2"
pass "Case302: data.length==2"

# 断言临时后端日志中有 n_mode=fallback_loop
sleep 1
if ! grep -q "INFERENCE_LOG" "$P33_BACKEND_LOG" 2>/dev/null; then
  log "Case302: Waiting 3s for backend log to flush..."
  sleep 3
fi
FALLBACK_LINE=$(grep "INFERENCE_LOG" "$P33_BACKEND_LOG" 2>/dev/null | grep '"n_mode".*"fallback_loop"' | tail -1)
if [ -z "$FALLBACK_LINE" ]; then
  fail "Case302: No INFERENCE_LOG with n_mode=fallback_loop in $P33_BACKEND_LOG"
fi
echo "$FALLBACK_LINE" >> "$OUT_FILE"
pass "Case302: Backend INFERENCE_LOG contains n_mode=fallback_loop"
log ""

log "=== Phase 3.3 phase3_n_single_call.sh: ALL PASS ==="
log "Output: $OUT_FILE"
exit 0
