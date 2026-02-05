#!/bin/bash
# phase3_timeout_semantics.sh: P3.2 超时语义分层验收
# T1: SYNC_WAIT_TIMEOUT_SEC=1, TASK_TIMEOUT_SEC=360, 重负载 -> 504 + code=sync_wait_timeout
# T2: T1 返回后轮询 /v1/tasks/{id} -> 最终 completed，output_urls 数量 == n
# T3: TASK_TIMEOUT_SEC=5, 重负载 -> 504 + code=task_timeout，任务最终 failed
# 输出: cli_tests/out/phase3_timeout_semantics.txt

set +e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT="$(mkdir -p "$OUT" && cd "$ROOT" && realpath "$OUT")"
OUT_FILE="$OUT/phase3_timeout_semantics.txt"
GW_PORT="${GW_PORT:-18020}"
GW_LOG="$OUT/phase3_timeout_gw.log"
BACKEND_URLS="${BACKEND_URLS:-http://127.0.0.1:8001,http://127.0.0.1:8002}"
ASSETS="$ROOT/cli_tests/assets"
IMG="${ASSETS}/dog.png"

gw_pid=""
rm -f "$OUT_FILE" "$GW_LOG" "$OUT"/phase3_t1_headers.txt "$OUT"/phase3_t1_body.txt "$OUT"/phase3_t3_headers.txt "$OUT"/phase3_t3_body.txt 2>/dev/null

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT_FILE"; }
pass() { echo "PASS: $*" | tee -a "$OUT_FILE"; }
fail() { echo "FAIL: $*" | tee -a "$OUT_FILE"; exit 1; }

cleanup() {
  [ -n "${gw_pid:-}" ] && kill "$gw_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# 准备图片（edits 需要至少一张）
if [ ! -f "$IMG" ]; then
  python3 -c "from PIL import Image; Image.new('RGB', (64,64), color='red').save('$OUT/phase3_edits_img.png')"
  IMG="$OUT/phase3_edits_img.png"
fi

log "=== Phase 3 timeout semantics: T1 (sync_wait_timeout) + T2 (poll completed) + T3 (task_timeout) ==="
log "GW_PORT=$GW_PORT BACKEND_URLS=$BACKEND_URLS OUT=$OUT_FILE"
log ""

# ---------- 启动临时网关：SYNC_WAIT_TIMEOUT_SEC=1, TASK_TIMEOUT_SEC=360 ----------
cd "$ROOT"
SYNC_WAIT_TIMEOUT_SEC=1 TASK_TIMEOUT_SEC=360 PLATFORM_MODE=1 BACKEND_URLS="$BACKEND_URLS" PORT="$GW_PORT" \
  uvicorn app.gateway.main:app --host 127.0.0.1 --port "$GW_PORT" >> "$GW_LOG" 2>&1 &
gw_pid=$!

for i in $(seq 1 50); do
  code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GW_PORT/healthz" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 0.1
done
code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GW_PORT/healthz" 2>/dev/null || echo "000")
[ "$code" = "200" ] || fail "gateway not ready (code=$code)"
log "gateway ready: http://127.0.0.1:$GW_PORT SYNC_WAIT_TIMEOUT_SEC=1 TASK_TIMEOUT_SEC=360"
sleep 0.3

BASE="http://127.0.0.1:$GW_PORT"

# ---------- T1: SYNC_WAIT_TIMEOUT_SEC=1，重负载（>1s 完成）-> 504 sync_wait_timeout ----------
log ""
log "--- T1: SYNC_WAIT_TIMEOUT_SEC=1, TASK_TIMEOUT_SEC=360, heavy load (steps=30,size=512,n=2) -> 504 sync_wait_timeout ---"
curl -sS -D "$OUT/phase3_t1_headers.txt" -o "$OUT/phase3_t1_body.txt" --max-time 15 -X POST "$BASE/v1/images/edits" \
  -F "prompt=Phase3 timeout T1" \
  -F "image=@$IMG" \
  -F "image=@$IMG" \
  -F "n=2" \
  -F "steps=30" \
  -F "size=512x512" \
  -F "sync=true" \
  -F "response_format=url"

CODE_T1=$(grep -oE "HTTP/[0-9.]+\s+[0-9]+" "$OUT/phase3_t1_headers.txt" 2>/dev/null | tail -1 | awk '{print $2}')
BODY_T1=$(cat "$OUT/phase3_t1_body.txt" 2>/dev/null)
log "  HTTP code: $CODE_T1"
echo "$BODY_T1" >> "$OUT_FILE"

[ "$CODE_T1" = "504" ] || fail "T1: expected HTTP 504, got $CODE_T1"
echo "$BODY_T1" | grep -q '"code"[[:space:]]*:[[:space:]]*"sync_wait_timeout"' || fail "T1: 504 body missing code=sync_wait_timeout"
echo "$BODY_T1" | grep -qi 'exceeded SYNC_WAIT_TIMEOUT_SEC\|sync wait timeout' || fail "T1: message missing exceeded SYNC_WAIT_TIMEOUT_SEC"

TASK_ID_T1=$(grep -i "x-task-id:" "$OUT/phase3_t1_headers.txt" 2>/dev/null | sed 's/.*: *//;s/\r//' | tr -d ' \n')
[ -n "$TASK_ID_T1" ] || fail "T1: missing X-Task-Id header"
log "  X-Task-Id: $TASK_ID_T1"
pass "T1: 504 + code=sync_wait_timeout, X-Task-Id present"

# ---------- T2: 轮询 /v1/tasks/{id} 直至 completed，output_urls 数量 == n ----------
log ""
log "--- T2: Poll /v1/tasks/$TASK_ID_T1 until completed, output_urls length == 2 ---"
MAX_POLL=360
POLL_INTERVAL=3
elapsed=0
while [ "$elapsed" -lt "$MAX_POLL" ]; do
  TASK_JSON=$(curl -sS --max-time 5 "$BASE/v1/tasks/$TASK_ID_T1" 2>/dev/null)
  STATUS=$(echo "$TASK_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
  if [ "$STATUS" = "completed" ]; then
    N_URLS=$(echo "$TASK_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
urls = d.get('output_urls') or []
print(len(urls))
" 2>/dev/null || echo "0")
    log "  status=completed at ${elapsed}s, output_urls length=$N_URLS"
    echo "$TASK_JSON" >> "$OUT_FILE"
    [ "$N_URLS" = "2" ] || fail "T2: expected output_urls length 2, got $N_URLS"
    pass "T2: completed, output_urls length == n (2)"
    break
  fi
  if [ "$STATUS" = "failed" ] || [ "$STATUS" = "expired" ] || [ "$STATUS" = "cancelled" ]; then
    log "  status=$STATUS (unexpected for T2)"
    echo "$TASK_JSON" >> "$OUT_FILE"
    fail "T2: task ended with status=$STATUS (expected completed)"
  fi
  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done
if [ "$elapsed" -ge "$MAX_POLL" ]; then
  fail "T2: timeout waiting for completed (${MAX_POLL}s)"
fi

# ---------- 重启临时网关：TASK_TIMEOUT_SEC=5 ----------
kill "$gw_pid" 2>/dev/null || true
gw_pid=""
sleep 1

SYNC_WAIT_TIMEOUT_SEC=120 TASK_TIMEOUT_SEC=5 PLATFORM_MODE=1 BACKEND_URLS="$BACKEND_URLS" PORT="$GW_PORT" \
  uvicorn app.gateway.main:app --host 127.0.0.1 --port "$GW_PORT" >> "$GW_LOG" 2>&1 &
gw_pid=$!

for i in $(seq 1 50); do
  code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GW_PORT/healthz" 2>/dev/null)
  [ "$code" = "200" ] && break
  sleep 0.1
done
code=$(curl -sS --max-time 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GW_PORT/healthz" 2>/dev/null || echo "000")
[ "$code" = "200" ] || fail "gateway (T3) not ready (code=$code)"
log "gateway (T3) ready: TASK_TIMEOUT_SEC=5"
sleep 0.3

# ---------- T3: TASK_TIMEOUT_SEC=5，重负载（>5s）-> 504 task_timeout，任务最终 failed ----------
log ""
log "--- T3: TASK_TIMEOUT_SEC=5, heavy load (steps=45,size=1024,n=2) -> 504 task_timeout, task eventually failed ---"
curl -sS -D "$OUT/phase3_t3_headers.txt" -o "$OUT/phase3_t3_body.txt" --max-time 30 -X POST "$BASE/v1/images/edits" \
  -F "prompt=Phase3 timeout T3" \
  -F "image=@$IMG" \
  -F "image=@$IMG" \
  -F "n=2" \
  -F "steps=45" \
  -F "size=1024x1024" \
  -F "sync=true" \
  -F "response_format=url"

CODE_T3=$(grep -oE "HTTP/[0-9.]+\s+[0-9]+" "$OUT/phase3_t3_headers.txt" 2>/dev/null | tail -1 | awk '{print $2}')
BODY_T3=$(cat "$OUT/phase3_t3_body.txt" 2>/dev/null)
log "  HTTP code: $CODE_T3"
echo "$BODY_T3" >> "$OUT_FILE"

[ "$CODE_T3" = "504" ] || fail "T3: expected HTTP 504, got $CODE_T3"
echo "$BODY_T3" | grep -q '"code"[[:space:]]*:[[:space:]]*"task_timeout"' || fail "T3: 504 body missing code=task_timeout"
echo "$BODY_T3" | grep -qi 'exceeded TASK_TIMEOUT_SEC\|deadline exceeded\|task timeout' || fail "T3: message missing exceeded TASK_TIMEOUT_SEC / deadline exceeded"

TASK_ID_T3=$(grep -i "x-task-id:" "$OUT/phase3_t3_headers.txt" 2>/dev/null | sed 's/.*: *//;s/\r//' | tr -d ' \n')
[ -n "$TASK_ID_T3" ] || fail "T3: missing X-Task-Id header"
log "  X-Task-Id: $TASK_ID_T3"
pass "T3: 504 + code=task_timeout, X-Task-Id present"

# 轮询直至任务 failed/expired
elapsed=0
T3_FINAL_STATUS=""
while [ "$elapsed" -lt 20 ]; do
  TASK_JSON=$(curl -sS --max-time 5 "$BASE/v1/tasks/$TASK_ID_T3" 2>/dev/null)
  T3_FINAL_STATUS=$(echo "$TASK_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
  if [ "$T3_FINAL_STATUS" = "failed" ] || [ "$T3_FINAL_STATUS" = "expired" ]; then
    log "  status=$T3_FINAL_STATUS at ${elapsed}s"
    echo "$TASK_JSON" >> "$OUT_FILE"
    pass "T3: task eventually failed/expired"
    break
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done
[ "$T3_FINAL_STATUS" = "failed" ] || [ "$T3_FINAL_STATUS" = "expired" ] || fail "T3: expected task failed/expired, got $T3_FINAL_STATUS"

log ""
log "=== Phase 3 phase3_timeout_semantics.sh: ALL PASS ==="
log "Output: $OUT_FILE"
exit 0
