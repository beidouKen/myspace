#!/bin/bash
# 30_batch_submit.sh
# Usage: ./30_batch_submit.sh
# Env: N (concurrency, default 6)

source "$(dirname "$0")/common.sh"
set -euo pipefail

N=${N:-6}
SUMMARY_FILE="$OUT_DIR/batch_summary.txt"
echo "Batch Test Summary (N=$N)" > "$SUMMARY_FILE"
echo "Started at: $(date)" >> "$SUMMARY_FILE"

log "Running 30_batch_submit.sh with N=$N..."

TASK_IDS=()

# 1. Submit N tasks
log "Submitting $N tasks..."
for i in $(seq 1 $N); do
    PAYLOAD=$(printf '{"prompt": "batch test %d", "steps": 1, "sync": false, "size": "256x256"}' "$i")
    RESP=$($CURL_AUTH -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$BASE_URL/v1/images/generations")
    TID=$(get_json_value "$RESP" "['task_id']")
    
    if [ -n "$TID" ] && [ "$TID" != "None" ]; then
        TASK_IDS+=("$TID")
        log "Submitted #$i: $TID"
    else
        log "Error submitting #$i: $RESP"
    fi
done

# 2. Poll All
log "Polling tasks..."
SUCCESS=0
FAILED=0
TOTAL=${#TASK_IDS[@]}

for tid in "${TASK_IDS[@]}"; do
    # Simple blocking poll for each (sequential polling for simplicity in bash)
    # Ideally should poll in parallel or use a loop over all, but this is a simple checker
    log "Waiting for $tid..."
    START_TIME=$(date +%s)
    STATUS="pending"
    while [[ "$STATUS" != "completed" && "$STATUS" != "failed" && "$STATUS" != "expired" ]]; do
       sleep 1
       RESP=$($CURL_AUTH "$BASE_URL/v1/tasks/$tid")
       STATUS=$(get_json_value "$RESP" "['status']")
       # Safety break
       NOW=$(date +%s)
       if [ $((NOW - START_TIME)) -gt 300 ]; then STATUS="timeout"; fi
    done
    
    DURATION=$(( $(date +%s) - START_TIME ))
    log "Task $tid finished as $STATUS in ${DURATION}s"
    
    if [ "$STATUS" == "completed" ]; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    
    echo "Task $tid: $STATUS (${DURATION}s)" >> "$SUMMARY_FILE"
done

echo "Finished at: $(date), Success: $SUCCESS, Failed: $FAILED" >> "$SUMMARY_FILE"
log "Summary saved to $SUMMARY_FILE"
pass "30_batch_submit.sh completed ($SUCCESS/$TOTAL success)"
