#!/bin/bash
# 94_prefer_async_returns_202.sh
# Gate: prefer_async=true 时立即返回 202 + task_id + poll_url，轮询 /v1/tasks 至 completed。

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
PROOF_FILE="$OUT_DIR/proof_94.txt"
API_KEY="${API_KEY:-mysecretkey}"
MAX_POLL_SEC="${MAX_POLL_SEC:-300}"

mkdir -p "$OUT_DIR" "$(dirname "$LOG_DIR")"
: > "$PROOF_FILE"

echo "=== 94 Prefer-Async Returns 202 Gate ===" | tee -a "$PROOF_FILE"
echo "BASE_URL=$BASE_URL" | tee -a "$PROOF_FILE"

# 前置：必须先通过 Gate 95 确认运行中网关已包含 prefer_async，避免旧进程导致假失败
if ! bash "$(dirname "$0")/95_gateway_rollout_verify.sh" >> "$PROOF_FILE" 2>&1; then
    echo "" | tee -a "$PROOF_FILE"
    echo "FAIL: Gate 95 未通过 — 当前运行的仍是旧 Gateway，未包含 prefer_async。请重启/重新启动 start.sh 后再运行 Gate 94。" | tee -a "$PROOF_FILE"
    exit 1
fi
echo "" | tee -a "$PROOF_FILE"

# 1) Chat with prefer_async=true
CHAT_BODY='{"model":"glm-image","messages":[{"role":"user","content":"a tree size=512x512 steps=20"}],"prefer_async":true}'
echo "" | tee -a "$PROOF_FILE"
echo "--- Request: POST /v1/chat/completions (prefer_async=true) ---" | tee -a "$PROOF_FILE"

HTTP_CHAT=$(curl -s -o "$OUT_DIR/chat_94.json" -w "%{http_code}" -X POST "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$CHAT_BODY")

echo "HTTP status: $HTTP_CHAT" | tee -a "$PROOF_FILE"
if [ "$HTTP_CHAT" != "202" ]; then
    echo "FAIL: Expected 202 for chat with prefer_async=true, got $HTTP_CHAT" | tee -a "$PROOF_FILE"
    cat "$OUT_DIR/chat_94.json" >> "$PROOF_FILE"
    exit 1
fi
TASK_ID=$(python3 -c "import json; d=json.load(open('$OUT_DIR/chat_94.json')); print(d.get('task_id',''))" 2>/dev/null || true)
POLL_URL=$(python3 -c "import json; d=json.load(open('$OUT_DIR/chat_94.json')); print(d.get('poll_url',''))" 2>/dev/null || true)
if [ -z "$TASK_ID" ]; then
    echo "FAIL: 202 response missing task_id" | tee -a "$PROOF_FILE"
    exit 1
fi
echo "task_id=$TASK_ID poll_url=$POLL_URL" | tee -a "$PROOF_FILE"
echo "PASS: Chat returned 202 with task_id and poll_url." | tee -a "$PROOF_FILE"

# 轮询至 completed
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
        echo "" | tee -a "$PROOF_FILE"
        echo "--- Final task (excerpt) ---" | tee -a "$PROOF_FILE"
        echo "$TASK_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps({k: d.get(k) for k in ('id','status','output_urls','n_outputs') if d.get(k) is not None}, indent=2))
" | tee -a "$PROOF_FILE"
        break
    fi
    if [ "$STATUS" = "failed" ] || [ "$STATUS" = "expired" ] || [ "$STATUS" = "cancelled" ]; then
        echo "FAIL: Task ended with status=$STATUS" | tee -a "$PROOF_FILE"
        echo "$TASK_JSON" | tee -a "$PROOF_FILE"
        exit 1
    fi
    sleep 2
done
echo "PASS: Poll until completed; result has output_urls/result." | tee -a "$PROOF_FILE"

# 2) Images generations with prefer_async=true
echo "" | tee -a "$PROOF_FILE"
echo "--- Request: POST /v1/images/generations (prefer_async=true) ---" | tee -a "$PROOF_FILE"
IMG_BODY='{"prompt":"a mountain","size":"512x512","steps":20,"sync":true,"prefer_async":true}'
HTTP_IMG=$(curl -s -o "$OUT_DIR/img_94.json" -w "%{http_code}" -X POST "$BASE_URL/v1/images/generations" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$IMG_BODY")
echo "HTTP status: $HTTP_IMG" | tee -a "$PROOF_FILE"
if [ "$HTTP_IMG" != "202" ]; then
    echo "FAIL: Expected 202 for images/generations with prefer_async=true, got $HTTP_IMG" | tee -a "$PROOF_FILE"
    cat "$OUT_DIR/img_94.json" >> "$PROOF_FILE"
    exit 1
fi
TASK_ID_IMG=$(python3 -c "import json; d=json.load(open('$OUT_DIR/img_94.json')); print(d.get('task_id',''))" 2>/dev/null || true)
if [ -z "$TASK_ID_IMG" ]; then
    echo "FAIL: 202 response missing task_id" | tee -a "$PROOF_FILE"
    exit 1
fi
echo "task_id=$TASK_ID_IMG" | tee -a "$PROOF_FILE"
echo "PASS: Images/generations returned 202 with task_id." | tee -a "$PROOF_FILE"

# 轮询 images task 至 completed
echo "" | tee -a "$PROOF_FILE"
echo "--- Polling images task $TASK_ID_IMG until completed ---" | tee -a "$PROOF_FILE"
POLL_START=$(date +%s)
while true; do
    NOW=$(date +%s)
    if [ $((NOW - POLL_START)) -gt "$MAX_POLL_SEC" ]; then
        echo "FAIL: Poll timeout" | tee -a "$PROOF_FILE"
        exit 1
    fi
    TASK_JSON=$(curl -s "$BASE_URL/v1/tasks/$TASK_ID_IMG" -H "Authorization: Bearer $API_KEY")
    STATUS=$(echo "$TASK_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
    echo "  status=$STATUS" | tee -a "$PROOF_FILE"
    if [ "$STATUS" = "completed" ]; then
        break
    fi
    if [ "$STATUS" = "failed" ] || [ "$STATUS" = "expired" ] || [ "$STATUS" = "cancelled" ]; then
        echo "FAIL: Task ended with status=$STATUS" | tee -a "$PROOF_FILE"
        exit 1
    fi
    sleep 2
done
echo "PASS: Images task completed." | tee -a "$PROOF_FILE"

echo "" | tee -a "$PROOF_FILE"
echo "=== Gate 94 PASS ===" | tee -a "$PROOF_FILE"
echo "Proof written to: $PROOF_FILE"
