#!/bin/bash
set -e
# 98_async_first_platform_flow.sh
source "$(dirname "$0")/_common.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_FILE="${OUT_DIR:-$ROOT/cli_tests/out}/platform_async_flow.txt"
mkdir -p "$(dirname "$OUT_FILE")"
rm -f "$OUT_FILE"
API_URL="$BASE_URL/v1/images/generations"

echo "=== Async First Flow (PLATFORM_MODE=1 default) ==="

# 1. Submit request without sync param
echo "Submitting request..."
RESP_JSON=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{ "prompt": "async platform test", "size": "1024x1024" }')

echo "Response: $RESP_JSON" >> "$OUT_FILE"

# Parse Task ID
TASK_ID=$(echo "$RESP_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('task_id', ''))")

if [ -z "$TASK_ID" ]; then
    echo "FAIL: No task_id returned. Is it sync?"
    exit 1
fi

echo "Task ID: $TASK_ID" >> "$OUT_FILE"

# 2. Poll Task
echo "Polling Task $TASK_ID..."
STATUS="pending"
while [ "$STATUS" != "completed" ] && [ "$STATUS" != "failed" ]; do
    sleep 1
    TASK_RESP=$(curl -s "$BASE_URL/v1/tasks/$TASK_ID")
    STATUS=$(echo "$TASK_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status'))")
    echo "Status: $STATUS"
done

echo "Final Status: $STATUS" >> "$OUT_FILE"

if [ "$STATUS" == "completed" ]; then
    echo "PASS: Task completed"
    
    # Check Result
    RESULT=$(echo "$TASK_RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('result'))")
    if [[ "$RESULT" == "data:image/png;base64"* ]]; then
         echo "PASS: Result is B64" >> "$OUT_FILE"
    else
         echo "FAIL: Result format" >> "$OUT_FILE"
         exit 1
    fi
else
    echo "FAIL: Task failed"
    exit 1
fi
