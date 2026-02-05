#!/bin/bash
# 86_idempotency_dedup.sh
# Gate: 幂等/去重 — 相同请求不产生多个独立任务；task_id 复用且有日志证据。

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
PROOF_FILE="$OUT_DIR/proof_86.txt"
GATEWAY_LOG="$LOG_DIR/gateway.log"
API_KEY="${API_KEY:-mysecretkey}"
PORT="${PORT:-8000}"

# 固定请求体（txt2img），保证可重复
BODY='{"prompt":"idempotency dedup test","size":"512x512","steps":20,"n":1}'

mkdir -p "$OUT_DIR" "$(dirname "$GATEWAY_LOG")"
: > "$PROOF_FILE"

curl_common() {
    curl -s -X POST "$BASE_URL/v1/images/generations" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$BODY" "$@"
}

echo "=== 86 Idempotency Dedup Gate ===" | tee -a "$PROOF_FILE"
echo "BASE_URL=$BASE_URL" | tee -a "$PROOF_FILE"

# 检查服务
if ! curl -s --max-time 2 "$BASE_URL/health" >/dev/null; then
    echo "WARN: Service not running. Start with: $ROOT/start.sh"
    echo "WARN: Service not running." >> "$PROOF_FILE"
    exit 1
fi
echo "Service UP." | tee -a "$PROOF_FILE"

# --- Part A: 3 次完全相同的请求，不带 Idempotency-Key（依赖 fingerprint 去重）---
echo "" | tee -a "$PROOF_FILE"
echo "--- Part A: 3 requests WITHOUT Idempotency-Key (fingerprint dedup) ---" | tee -a "$PROOF_FILE"

R1=$(curl_common)
TASK_ID_1=$(echo "$R1" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('task_id') or d.get('data', [{}])[0].get('url','') or '')" 2>/dev/null || echo "")
STATUS_1=$(echo "$R1" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
echo "Req1: task_id=$TASK_ID_1 status=$STATUS_1" | tee -a "$PROOF_FILE"
if echo "$R1" | grep -q "error"; then
    echo "FAIL: Req1 error: $R1" | tee -a "$PROOF_FILE"
    exit 1
fi

R2=$(curl_common)
TASK_ID_2=$(echo "$R2" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('task_id') or '')" 2>/dev/null || echo "")
STATUS_2=$(echo "$R2" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
echo "Req2: task_id=$TASK_ID_2 status=$STATUS_2" | tee -a "$PROOF_FILE"

R3=$(curl_common)
TASK_ID_3=$(echo "$R3" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('task_id') or '')" 2>/dev/null || echo "")
STATUS_3=$(echo "$R3" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
echo "Req3: task_id=$TASK_ID_3 status=$STATUS_3" | tee -a "$PROOF_FILE"

if [ -z "$TASK_ID_1" ]; then
    echo "FAIL: Req1 did not return task_id" | tee -a "$PROOF_FILE"
    exit 1
fi
if [ "$TASK_ID_1" != "$TASK_ID_2" ] || [ "$TASK_ID_1" != "$TASK_ID_3" ]; then
    echo "FAIL: Part A - task_id must be same for all 3 (got $TASK_ID_1, $TASK_ID_2, $TASK_ID_3)" | tee -a "$PROOF_FILE"
    exit 1
fi
echo "PASS: Part A - same task_id for 3 requests without key: $TASK_ID_1" | tee -a "$PROOF_FILE"

# --- Part B: 3 次带同一 Idempotency-Key 的请求 ---
echo "" | tee -a "$PROOF_FILE"
echo "--- Part B: 3 requests WITH Idempotency-Key: demo-key-123 ---" | tee -a "$PROOF_FILE"

R4=$(curl_common -H "Idempotency-Key: demo-key-123")
TASK_ID_4=$(echo "$R4" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('task_id') or '')" 2>/dev/null || echo "")
STATUS_4=$(echo "$R4" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
echo "Req4: task_id=$TASK_ID_4 status=$STATUS_4" | tee -a "$PROOF_FILE"

R5=$(curl_common -H "Idempotency-Key: demo-key-123")
TASK_ID_5=$(echo "$R5" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('task_id') or '')" 2>/dev/null || echo "")
STATUS_5=$(echo "$R5" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
echo "Req5: task_id=$TASK_ID_5 status=$STATUS_5" | tee -a "$PROOF_FILE"

R6=$(curl_common -H "Idempotency-Key: demo-key-123")
TASK_ID_6=$(echo "$R6" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('task_id') or '')" 2>/dev/null || echo "")
STATUS_6=$(echo "$R6" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
echo "Req6: task_id=$TASK_ID_6 status=$STATUS_6" | tee -a "$PROOF_FILE"

if [ -z "$TASK_ID_4" ]; then
    echo "FAIL: Req4 did not return task_id" | tee -a "$PROOF_FILE"
    exit 1
fi
if [ "$TASK_ID_4" != "$TASK_ID_5" ] || [ "$TASK_ID_4" != "$TASK_ID_6" ]; then
    echo "FAIL: Part B - task_id must be same for all 3 with key (got $TASK_ID_4, $TASK_ID_5, $TASK_ID_6)" | tee -a "$PROOF_FILE"
    exit 1
fi
echo "PASS: Part B - same task_id for 3 requests with key: $TASK_ID_4" | tee -a "$PROOF_FILE"

# --- 证据：Gateway 日志中的 IDEMPOTENCY_HIT ---
echo "" | tee -a "$PROOF_FILE"
echo "--- IDEMPOTENCY_HIT evidence from Gateway log ---" | tee -a "$PROOF_FILE"
if [ -f "$GATEWAY_LOG" ]; then
    grep "IDEMPOTENCY_HIT" "$GATEWAY_LOG" | tail -20 >> "$PROOF_FILE" || true
    grep "IDEMPOTENCY_MISS" "$GATEWAY_LOG" | tail -10 >> "$PROOF_FILE" || true
else
    echo "(gateway.log not found at $GATEWAY_LOG)" >> "$PROOF_FILE"
fi

# --- 可选：metrics 中的命中计数 ---
echo "" | tee -a "$PROOF_FILE"
echo "--- Metrics idempotency counts ---" | tee -a "$PROOF_FILE"
if curl -s --max-time 2 "$BASE_URL/metrics" 2>/dev/null | tee -a "$PROOF_FILE" | grep -q "idempotency"; then
    true
fi

echo ""
echo "=== Gate 86 PASS: Idempotency dedup verified ==="
echo "Proof written to: $PROOF_FILE"
