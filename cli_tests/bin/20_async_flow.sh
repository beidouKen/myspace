#!/bin/bash
# 20_async_flow.sh
# Usage: ./20_async_flow.sh

source "$(dirname "$0")/common.sh"
set -euo pipefail

log "Running 20_async_flow.sh..."

# 1. Submit Task
log "Submitting Async Task..."
PAYLOAD='{"prompt": "async flow test", "steps": 2, "sync": false, "size": "256x256"}'
RESP=$($CURL_AUTH -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$BASE_URL/v1/images/generations")

TASK_ID=$(get_json_value "$RESP" "['task_id']")
log "Task ID: $TASK_ID"

if [ -z "$TASK_ID" ] || [ "$TASK_ID" == "None" ]; then
    fail "No task_id in response: $RESP"
fi

# 2. Poll Status
STATUS="pending"
MAX_RETRIES=20
RETRY_COUNT=0

while [[ "$STATUS" != "completed" && "$STATUS" != "failed" && "$STATUS" != "cancelled" && "$STATUS" != "expired" ]]; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        fail "Timeout polling task $TASK_ID"
    fi
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
    
    RESP=$($CURL_AUTH "$BASE_URL/v1/tasks/$TASK_ID")
    echo "$RESP" > "$OUT_DIR/async_${TASK_ID}_status.log"
    STATUS=$(get_json_value "$RESP" "['status']")
    log "Poll #$RETRY_COUNT: Status=$STATUS"
done

if [ "$STATUS" != "completed" ]; then
    fail "Task ended with status: $STATUS"
fi

pass "Task completed successfully."

# 3. Download Result
IMG_URL="$BASE_URL/outputs/${TASK_ID}.png"
DEST="$OUT_DIR/async_${TASK_ID}.png"

log "Downloading result from $IMG_URL..."
if curl -s -f -o "$DEST" "$IMG_URL"; then
    pass "Download OK"
else
    fail "Download failed"
fi

# 4. Validate
FILE_INFO=$(file "$DEST")
if [[ "$FILE_INFO" == *"PNG image data"* ]]; then
    pass "File validation OK"
else
    fail "File validation failed: $FILE_INFO"
fi

pass "20_async_flow.sh completed successfully."
