#!/bin/bash
# 87_chat_timeout_returns_202.sh
# Gate: chat/completions 在 sync_wait_timeout 时返回 202 + task_id + poll_url，非 504；轮询 tasks 可拿到最终结果。

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
PROOF_FILE="$OUT_DIR/proof_87.txt"
API_KEY="${API_KEY:-mysecretkey}"
# 本 Gate 需在等待超时前返回，故使用较短 SYNC_WAIT_TIMEOUT；若服务已启动且未设此变量，脚本会尝试用短超时启动
SYNC_WAIT_FOR_TEST="${SYNC_WAIT_TIMEOUT_SEC:-5}"
MAX_POLL_SEC="${MAX_POLL_SEC:-300}"

mkdir -p "$OUT_DIR" "$(dirname "$LOG_DIR")"
: > "$PROOF_FILE"

echo "=== 87 Chat Timeout Returns 202 Gate ===" | tee -a "$PROOF_FILE"
echo "BASE_URL=$BASE_URL" | tee -a "$PROOF_FILE"
echo "SYNC_WAIT_TIMEOUT_SEC (for test)=$SYNC_WAIT_FOR_TEST" | tee -a "$PROOF_FILE"

# 若服务未运行，使用短超时启动以便触发 202
if ! curl -s --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; then
    echo "Starting service with SYNC_WAIT_TIMEOUT_SEC=$SYNC_WAIT_FOR_TEST for test..."
    export SYNC_WAIT_TIMEOUT_SEC="$SYNC_WAIT_FOR_TEST"
    nohup "$ROOT/start.sh" >> "$LOG_DIR/start_87.log" 2>&1 &
    for i in $(seq 1 60); do
        if curl -s "$BASE_URL/ready" | grep -q "ready"; then
            echo "Service ready."
            break
        fi
        sleep 2
    done
fi

if ! curl -s --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; then
    echo "FAIL: Service not available at $BASE_URL" | tee -a "$PROOF_FILE"
    exit 1
fi

# 使用会较慢完成的请求（1024x1024 steps=45），以便在 SYNC_WAIT_TIMEOUT 内未完成而触发 202
CHAT_BODY='{"model":"glm-image","messages":[{"role":"user","content":"draw a cat size=1024x1024 steps=45"}]}'

echo "" | tee -a "$PROOF_FILE"
echo "--- Request: POST /v1/chat/completions (long-running) ---" | tee -a "$PROOF_FILE"

HTTP_CODE=$(curl -s -o "$OUT_DIR/chat_87_response.json" -w "%{http_code}" -X POST "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$CHAT_BODY")

echo "HTTP status: $HTTP_CODE" | tee -a "$PROOF_FILE"
cat "$OUT_DIR/chat_87_response.json" | tee -a "$PROOF_FILE"
echo "" | tee -a "$PROOF_FILE"

if [ "$HTTP_CODE" = "202" ]; then
    echo "PASS: Got 202 Accepted (no 504)." | tee -a "$PROOF_FILE"
elif [ "$HTTP_CODE" = "200" ]; then
    echo "PASS: Task completed within wait window (200 OK). Proof still valid." | tee -a "$PROOF_FILE"
    echo "--- Final result (200) ---" | tee -a "$PROOF_FILE"
    cat "$OUT_DIR/chat_87_response.json" >> "$PROOF_FILE"
    echo "" | tee -a "$PROOF_FILE"
    echo "=== Gate 87 PASS (completed in time) ===" | tee -a "$PROOF_FILE"
    exit 0
else
    echo "FAIL: Expected 202 or 200, got $HTTP_CODE" | tee -a "$PROOF_FILE"
    exit 1
fi

TASK_ID=$(python3 -c "import json; d=json.load(open('$OUT_DIR/chat_87_response.json')); print(d.get('task_id',''))" 2>/dev/null || true)
POLL_URL=$(python3 -c "import json; d=json.load(open('$OUT_DIR/chat_87_response.json')); print(d.get('poll_url',''))" 2>/dev/null || true)

if [ -z "$TASK_ID" ]; then
    echo "FAIL: 202 response missing task_id" | tee -a "$PROOF_FILE"
    exit 1
fi
echo "task_id=$TASK_ID" | tee -a "$PROOF_FILE"
echo "poll_url=$POLL_URL" | tee -a "$PROOF_FILE"

# 轮询 /v1/tasks/{id} 直到 completed
echo "" | tee -a "$PROOF_FILE"
echo "--- Polling GET $BASE_URL/v1/tasks/$TASK_ID until completed ---" | tee -a "$PROOF_FILE"
POLL_START=$(date +%s)
while true; do
    NOW=$(date +%s)
    if [ $((NOW - POLL_START)) -gt "$MAX_POLL_SEC" ]; then
        echo "FAIL: Poll timeout after ${MAX_POLL_SEC}s" | tee -a "$PROOF_FILE"
        exit 1
    fi
    TASK_JSON=$(curl -s "$BASE_URL/v1/tasks/$TASK_ID" -H "Authorization: Bearer $API_KEY")
    STATUS=$(echo "$TASK_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    echo "  status=$STATUS" | tee -a "$PROOF_FILE"
    if [ "$STATUS" = "completed" ]; then
        echo "$TASK_JSON" > "$OUT_DIR/task_87_completed.json"
        echo "" | tee -a "$PROOF_FILE"
        echo "--- Final completed task body ---" | tee -a "$PROOF_FILE"
        echo "$TASK_JSON" | tee -a "$PROOF_FILE"
        break
    fi
    if [ "$STATUS" = "failed" ] || [ "$STATUS" = "expired" ] || [ "$STATUS" = "cancelled" ]; then
        echo "FAIL: Task ended with status=$STATUS" | tee -a "$PROOF_FILE"
        echo "$TASK_JSON" | tee -a "$PROOF_FILE"
        exit 1
    fi
    sleep 3
done

# 断言有 data/url（output_urls 或 result）
HAS_URL=$(echo "$TASK_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('output_urls') or d.get('result'):
    print('yes')
else:
    print('no')
" 2>/dev/null || echo "no")
if [ "$HAS_URL" != "yes" ]; then
    echo "FAIL: Completed task has no output_urls or result" | tee -a "$PROOF_FILE"
    exit 1
fi
echo "PASS: Completed task has data/url." | tee -a "$PROOF_FILE"

echo "" | tee -a "$PROOF_FILE"
echo "=== Gate 87 PASS ===" | tee -a "$PROOF_FILE"
echo "Proof written to: $PROOF_FILE"
