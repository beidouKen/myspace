#!/bin/bash
set -e

# --- Configuration ---
export PYTHONUNBUFFERED=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
LOG_DIR="${LOG_DIR:-$PWD/logs}"
INPUT_IMG="$OUT_DIR/img2img_input.png"
OUTPUT_IMG="$OUT_DIR/img2img_output.png"
PROOF_FILE="$OUT_DIR/img2img_proof.txt"
PORT=8000

mkdir -p "$OUT_DIR"
rm -f "$OUTPUT_IMG" "$PROOF_FILE"

# --- 1. Generate Dummy Input Image ---
# Verify python has PIL (it should)
echo "INFO: Generating input image..."
python3 -c "from PIL import Image; Image.new('RGB', (512, 512), color='red').save('$INPUT_IMG')"

# --- 2. Ensure main service UP (do NOT kill/restart) ---
if ! curl -s --max-time 5 http://localhost:$PORT/health | grep -q "ok"; then
    echo "FAIL: Main service not up. Start with ./start.sh first."
    exit 1
fi

# --- 3. Smoke Test (/v1/images/edits) ---
echo "---------------------------------------------------"
echo "[TEST] Img2Img Smoke (Sync=True, URL format)"
echo "Prompt: turn this into a watercolor style"
echo "Input: $INPUT_IMG"

START_TIME=$(date +%s)
RESP=$(curl -s --max-time 300 -X POST http://localhost:$PORT/v1/images/edits \
  -H "Authorization: Bearer mysecretkey" \
  -F "prompt=turn this into a watercolor style" \
  -F "image=@$INPUT_IMG" \
  -F "sync=true" \
  -F "response_format=url" \
  -F "strength=0.75" \
  -F "size=1024x1024")

# Parse URL
URL=$(echo "$RESP" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data', [{}])[0].get('url', ''))")
TASK_ID=$(echo "$URL" | awk -F'/' '{print $NF}' | sed 's/\.png//')

echo "INFO: Received URL: $URL"
echo "INFO: Task ID: $TASK_ID"

if [ -z "$URL" ]; then
    echo "FAIL: No URL in response."
    echo "Raw Response: $RESP"
    exit 1
fi

# Download Output
curl -s --max-time 60 "$URL" -o "$OUTPUT_IMG"
echo "INFO: Downloaded to $OUTPUT_IMG"

# --- 4. Verify Log ---
echo "INFO: Searching logs for Img2Img entry..."
LOG_MSG=""
for i in {1..30}; do
    LOG_MSG=$(find $LOG_DIR -name "backend_*.log" -print0 | xargs -0 cat | grep "$TASK_ID" | grep "INFERENCE_LOG" | tail -n 1)
    if [ -n "$LOG_MSG" ]; then break; fi
    sleep 1
done

if [ -z "$LOG_MSG" ]; then
    echo "FAIL: Log not found for $TASK_ID"
    exit 1
fi

# --- 5. Generate Proof ---
{
    echo "REQUEST_PARAMS: prompt='turn this into a watercolor style', strength=0.75, size=1024x1024, sync=true"
    echo "RESPONSE_URL: $URL"
    echo "INPUT_FILE_CHECK: $(file $INPUT_IMG)"
    echo "OUTPUT_FILE_CHECK: $(file $OUTPUT_IMG)"
    echo "LS_OUTPUT: $(ls -lh $OUTPUT_IMG)"
    echo "INFERENCE_LOG: $LOG_MSG"
} > "$PROOF_FILE"

# --- 6. Assertions ---
# Check mode=img2img
if [[ "$LOG_MSG" == *'"mode": "img2img"'* ]]; then
    echo "PASS: Mode Verified."
else
    echo "FAIL: Wrong mode in log."
    exit 1
fi

# Check strength=0.75
if [[ "$LOG_MSG" == *'"strength": 0.75'* ]]; then
    echo "PASS: Strength Verified."
else
    echo "FAIL: Strength mismatch."
    exit 1
fi

# Check size (should have been resized to 1024x1024 since we passed it)
if [[ "$LOG_MSG" == *'"size": "1024x1024"'* ]]; then
    echo "PASS: Size Verified."
else
    echo "FAIL: Size mismatch (Expected 1024x1024)."
    exit 1
fi

echo "---------------------------------------------------"
echo "IMG2IMG TEST PASSED"
