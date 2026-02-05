#!/bin/bash
set -e

# --- 1. Configuration for Final Acceptance ---
export PYTHONUNBUFFERED=1

# Stable Mode Rule: Request > Env > Default
export DEFAULT_STEPS=45
export DEFAULT_SIZE="1024x1024"
export DEFAULT_GUIDANCE=4.0
export MIN_STEPS=20
export MAX_STEPS=80
export RETRY_ON_BAD_OUTPUT=1
export RETRY_EXTRA_STEPS=10

export LOG_DIR="${LOG_DIR:-$PWD/logs}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
export MODEL_DIR="${MODEL_DIR:-/root/models/zai-org/GLM-Image}"
export PORT="${PORT:-8000}"
source "$(dirname "$0")/_common.sh"
mkdir -p "$OUT_DIR"
PROOF_FILE="$OUT_DIR/default_stable_proof.txt"
IMG_FILE="$OUT_DIR/default_stable.png"
rm -f "$PROOF_FILE" "$IMG_FILE"

# --- 2. Assume main service already up (do NOT kill/restart); wait for health ---
echo "INFO: Waiting for main service (assume already started by ./start.sh)..."
for i in {1..90}; do
    if curl -s --max-time 5 "$BASE_URL/health" | grep -q "ok"; then
        if curl -s --max-time 5 "http://127.0.0.1:${BACKEND_PORT_START:-8001}/health" | grep -q "ok"; then
           echo "INFO: Service UP."
           break
        fi
    fi
    [ $i -eq 90 ] && { echo "FAIL: Service not up after 90 tries."; exit 1; }
    sleep 2
done

# --- 3. Acceptance Test (Case 1) ---
echo "---------------------------------------------------"
echo "[TEST 1] Acceptance: Prompt Only + Sync=True -> Expect Defaults"
# Scenario: prompt + sync + response_format=url. NO steps/size/seed.
RESP=$(curl -s --max-time 300 -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Final Acceptance Test Stable Mode",
    "sync": true,
    "response_format": "url"
  }')

# Extract Data
URL=$(echo "$RESP" | python3 -c "import sys, json; print(json.load(sys.stdin)['data'][0]['url'])")

# Since sync=true, we don't get the task_id directly in the root of the standard OpenAI response,
# but the Gateway implementation might wrap it or the URL contains it: ".../outputs/{task_id}.png"
# Let's extract Task ID from URL. Example: $BASE_URL/outputs/abc-123.png
TASK_ID=$(echo "$URL" | awk -F'/' '{print $NF}' | sed 's/\.png//')

echo "INFO: Received URL: $URL"
echo "INFO: Derived Task ID: $TASK_ID"

if [ -z "$URL" ] || [ -z "$TASK_ID" ]; then
    echo "FAIL: Failed to get URL or Task ID from response: $RESP"
    exit 1
fi

# Download
curl -s --max-time 60 "$URL" -o "$IMG_FILE"
echo "INFO: Image downloaded to $IMG_FILE"

# Find Log
echo "INFO: Hunting for INFERENCE_LOG..."
LOG_MSG=""
for i in {1..60}; do
    LOG_MSG=$(find $LOG_DIR -name "backend_*.log" -print0 | xargs -0 cat | grep "$TASK_ID" | grep "INFERENCE_LOG" | tail -n 1)
    if [ -n "$LOG_MSG" ]; then
        break
    fi
    sleep 1
done

if [ -z "$LOG_MSG" ]; then
    echo "FAIL: Log not found for $TASK_ID"
    exit 1
fi

# Write Proof
{
    echo "URL: $URL"
    echo "FILE_CHECK: $(file $IMG_FILE)"
    echo "LS_CHECK: $(ls -lh $IMG_FILE)"
    echo "LOG: $LOG_MSG"
} > "$PROOF_FILE"

# Verify Content
if [[ "$LOG_MSG" == *'"steps": 45'* ]] && [[ "$LOG_MSG" == *'"size": "1024x1024"'* ]]; then
    echo "PASS: Case 1 Verified."
else
    echo "FAIL: Case 1 Mismatch. Expected steps=45, size=1024x1024."
    echo "LOG WAS: $LOG_MSG"
    exit 1
fi

# --- 4. Clamping Test (Case 2) ---
echo "---------------------------------------------------"
echo "[TEST 2] Clamping: steps=10 -> Expect 20"
RESP=$(curl -s --max-time 120 -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Clamping Test",
    "steps": 10
  }')
# Async request returns Task ID directly
TASK_ID=$(echo "$RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('task_id', ''))")
echo "INFO: Tracked Task ID: $TASK_ID"

LOG_MSG=""
for i in {1..60}; do
    LOG_MSG=$(find $LOG_DIR -name "backend_*.log" -print0 | xargs -0 cat | grep "$TASK_ID" | grep "INFERENCE_LOG" | tail -n 1)
    if [ -n "$LOG_MSG" ]; then break; fi
    sleep 2
done

echo "LOG: $LOG_MSG"
if [[ "$LOG_MSG" == *'"steps": 20'* ]]; then
    echo "PASS: Case 2 Verified."
else
    echo "FAIL: Case 2 Mismatch. Expected steps=20."
    exit 1
fi

# --- 5. Invalid Test (Case 3) ---
echo "---------------------------------------------------"
echo "[TEST 3] Invalid Size -> Expect Failure"
# Now Gateway validates size immediately (HTTP 400), so we expect error in response, not a task_id.
RESP=$(curl -s --max-time 10 -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Bad Size Test",
    "size": "500x500"
  }')

echo "RESP: $RESP"

if echo "$RESP" | grep -q "Invalid size"; then
    echo "PASS: Case 3 Verified (Immediate 400)."
else
    echo "FAIL: Case 3 Mismatch. Expected 400 with Invalid size."
    exit 1
fi

echo "---------------------------------------------------"
echo "ALL ACCEPTANCE TESTS PASSED"
