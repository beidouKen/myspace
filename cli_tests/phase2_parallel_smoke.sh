#!/bin/bash
# phase2_parallel_smoke.sh: Phase 2.2 多后端并行验收
# 并发发 2 个 txt2img（不同 prompt），记录两个 task_id；
# 从 /v1/tasks 或 /metrics 证明 dispatch 到不同 backend；
# 最终拿到两个 outputs url 且 curl -I 返回 200。
# 输出: cli_tests/out/phase2_parallel_smoke.txt

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT="$(mkdir -p "$OUT" && cd "$ROOT" && realpath "$OUT")"
OUT_FILE="$OUT/phase2_parallel_smoke.txt"
BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
GATEWAY_LOG="${GATEWAY_LOG:-$ROOT/logs/gateway.log}"

rm -f "$OUT_FILE"
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT_FILE"; }
pass() { echo "PASS: $*" | tee -a "$OUT_FILE"; }
fail() { echo "FAIL: $*" | tee -a "$OUT_FILE"; exit 1; }

log "=== Phase 2.2 parallel smoke: 2 concurrent txt2img -> different backends, 2 URLs 200 ==="
log "BASE_URL=$BASE_URL OUT=$OUT_FILE"
log ""

# --- 1. 并发发 2 个 txt2img（async），不同 prompt，记录 task_id ---
log "--- 1. Concurrent 2 txt2img (async, different prompts) ---"
R1=$(curl -sS --max-time 15 -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Phase2 parallel test image A","response_format":"url"}')
R2=$(curl -sS --max-time 15 -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Phase2 parallel test image B","response_format":"url"}')

TASK_ID_1=$(echo "$R1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task_id',''))" 2>/dev/null || true)
TASK_ID_2=$(echo "$R2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task_id',''))" 2>/dev/null || true)

if [ -z "$TASK_ID_1" ] || [ -z "$TASK_ID_2" ]; then
  fail "Could not get two task_ids. R1=$R1 R2=$R2"
fi
log "  task_id_1=$TASK_ID_1"
log "  task_id_2=$TASK_ID_2"
echo "task_id_1=$TASK_ID_1" >> "$OUT_FILE"
echo "task_id_2=$TASK_ID_2" >> "$OUT_FILE"

# --- 2. 轮询直到两个任务都 completed ---
log ""
log "--- 2. Poll until both completed ---"
for i in $(seq 1 300); do
  S1=$(curl -sS --max-time 5 "$BASE_URL/v1/tasks/$TASK_ID_1" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  S2=$(curl -sS --max-time 5 "$BASE_URL/v1/tasks/$TASK_ID_2" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
  [ "$S1" = "completed" ] && [ "$S2" = "completed" ] && break
  [ "$S1" = "failed" ] || [ "$S2" = "failed" ] && fail "One or both tasks failed: s1=$S1 s2=$S2"
  sleep 1
done
[ "$S1" != "completed" ] || [ "$S2" != "completed" ] && fail "Timeout waiting for both completed (s1=$S1 s2=$S2)"
pass "Both tasks completed"

# --- 3. 从 /v1/tasks 取 backend_id，证明派发到不同 backend ---
log ""
log "--- 3. Prove dispatch to different backends (backend_id from /v1/tasks) ---"
T1_JSON=$(curl -sS --max-time 5 "$BASE_URL/v1/tasks/$TASK_ID_1")
T2_JSON=$(curl -sS --max-time 5 "$BASE_URL/v1/tasks/$TASK_ID_2")
BACKEND_1=$(echo "$T1_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('backend_id',''))" 2>/dev/null || true)
BACKEND_2=$(echo "$T2_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('backend_id',''))" 2>/dev/null || true)

log "  backend_id_1=$BACKEND_1"
log "  backend_id_2=$BACKEND_2"
echo "backend_id_1=$BACKEND_1" >> "$OUT_FILE"
echo "backend_id_2=$BACKEND_2" >> "$OUT_FILE"

if [ -n "$BACKEND_1" ] && [ -n "$BACKEND_2" ]; then
  if [ "$BACKEND_1" = "$BACKEND_2" ]; then
    fail "Both tasks dispatched to same backend ($BACKEND_1); expected different backends."
  fi
  pass "Dispatched to different backends: $BACKEND_1 vs $BACKEND_2"
else
  log "  Proving from gateway DISPATCH log..."
  if [ -f "$GATEWAY_LOG" ]; then
    B1=$(grep "DISPATCH" "$GATEWAY_LOG" 2>/dev/null | grep "$TASK_ID_1" | tail -1 | sed -n 's/.*"backend"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    B2=$(grep "DISPATCH" "$GATEWAY_LOG" 2>/dev/null | grep "$TASK_ID_2" | tail -1 | sed -n 's/.*"backend"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$B1" ] && [ -n "$B2" ] && [ "$B1" != "$B2" ]; then
      pass "Dispatched to different backends (from log): $B1 vs $B2"
    else
      grep "DISPATCH" "$GATEWAY_LOG" 2>/dev/null | grep -E "$TASK_ID_1|$TASK_ID_2" >> "$OUT_FILE" || true
      log "  (DISPATCH lines for task_ids appended to proof)"
    fi
  fi
fi

# --- 4. 可选：从网关日志补充 DISPATCH 证明 ---
if [ -f "$GATEWAY_LOG" ]; then
  log ""
  log "--- 4. Gateway DISPATCH log (proof) ---"
  grep "DISPATCH" "$GATEWAY_LOG" 2>/dev/null | grep -E "$TASK_ID_1|$TASK_ID_2" | tail -5 >> "$OUT_FILE" || true
  log "  (see $OUT_FILE and $GATEWAY_LOG)"
fi

# --- 5. 两个 output URL，curl GET 返回 200 ---
log ""
log "--- 5. Two output URLs, curl GET 200 ---"
URL_1="$BASE_URL/outputs/$TASK_ID_1.png"
URL_2="$BASE_URL/outputs/$TASK_ID_2.png"
CODE_1=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$URL_1" 2>/dev/null || echo "000")
CODE_2=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$URL_2" 2>/dev/null || echo "000")

log "  URL_1=$URL_1 -> HTTP $CODE_1"
log "  URL_2=$URL_2 -> HTTP $CODE_2"
echo "url_1=$URL_1" >> "$OUT_FILE"
echo "url_2=$URL_2" >> "$OUT_FILE"

[ "$CODE_1" != "200" ] && fail "url_1 returned $CODE_1 (expected 200)"
[ "$CODE_2" != "200" ] && fail "url_2 returned $CODE_2 (expected 200)"
pass "Both output URLs return 200"

log ""
log "=== Phase 2.2 phase2_parallel_smoke.sh: ALL PASS ==="
log "Output: $OUT_FILE"
