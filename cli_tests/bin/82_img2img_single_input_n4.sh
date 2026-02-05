#!/bin/bash
# 82_img2img_single_input_n4.sh
# Tests image preprocessing in Gateway

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
LOG_DIR="$ROOT/logs"
INPUT_IMG="$OUT_DIR/input_500x500.png"
OUTPUT_JSON="$OUT_DIR/response_82.json"
PROOF_FILE="$OUT_DIR/proof_82.txt"
GATEWAY_LOG="$LOG_DIR/gateway.log"
PORT=8000

mkdir -p "$OUT_DIR"
rm -f "$OUTPUT_JSON" "$PROOF_FILE"

# 1. Generate 500x500 Image
echo "INFO: Generating 500x500 input image..."
python3 -c "from PIL import Image; Image.new('RGB', (500, 500), color='blue').save('$INPUT_IMG')"

# 2. Check Service
echo "INFO: Checking service status..."
if ! curl -s --max-time 2 http://localhost:$PORT/health >/dev/null; then
    echo "WARN: Service not running. Starting..."
    nohup $ROOT/start.sh >/dev/null 2>&1 &
    # Wait for ready
    echo "Waiting for service ready..."
    for i in {1..60}; do
        if curl -s http://localhost:$PORT/ready | grep -q "ready"; then
            echo "Service UP and READY."
            break
        fi
        sleep 2
    done
else
    echo "Service is running."
fi

# 3. Test AUTO_RESIZE (Default)
echo "---------------------------------------------------"
echo "[TEST] Auto Resize (Default)"
# We expect 200 OK and "resized_padded" log
START_TIME=$(date +%s)
# Need to use -F for multipart
echo "Sending request with 500x500 image..."
curl -s -X POST http://localhost:$PORT/v1/images/edits \
  -H "Authorization: Bearer mysecretkey" \
  -F "prompt=resize test" \
  -F "image=@$INPUT_IMG" \
  -F "size=1024x1024" \
  -F "strength=0.75" \
  -F "sync=true" \
  -F "response_format=url" \
  > "$OUTPUT_JSON"

if grep -q "error" "$OUTPUT_JSON"; then
    echo "FAIL: Unexpected error in response"
    cat "$OUTPUT_JSON"
    exit 1
fi

URL=$(cat "$OUTPUT_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data', [{}])[0].get('url', ''))")
if [ -z "$URL" ] || [ "$URL" == "None" ]; then
    echo "FAIL: No URL returned"
    cat "$OUTPUT_JSON"
    exit 1
fi
echo "SUCCESS: Got URL $URL"

# Find Log
# We need to find the PREPROCESS_IMAGE log that happened after START_TIME
# But simple grep is easier if we look for the specific dimensions
echo "INFO: Searching gateway log for PREPROCESS event..."
sleep 2 # wait for flush
LOG_LINE=$(grep "PREPROCESS_IMAGE" "$GATEWAY_LOG" | grep "500x500" | tail -n 1)

if [ -z "$LOG_LINE" ]; then
    echo "FAIL: No preprocessing log found for 500x500"
    exit 1
fi

echo "Found Log: $LOG_LINE"
echo "$LOG_LINE" >> "$PROOF_FILE"

if echo "$LOG_LINE" | grep -q "resized_padded"; then
    echo "PASS: Correct action 'resized_padded'"
else
    echo "FAIL: Incorrect action"
    exit 1
fi

# 4. Test STRICT_IMAGE_SIZE=1
echo "---------------------------------------------------"
echo "[TEST] Strict Mode"

# Kill running service
echo "INFO: Restarting service in STRICT mode..."
pkill -f "start.sh" || true
pkill -f "uvicorn" || true
wait || true
sleep 5

# Start with STRICT_IMAGE_SIZE=1
export STRICT_IMAGE_SIZE=1
export AUTO_RESIZE=0 # Should be irrelevant if STRICT=1, but let's be sure
nohup $ROOT/start.sh > "$LOG_DIR/start_strict.log" 2>&1 &

# Wait for healthy
echo "Waiting for service (Strict Mode)..."
for i in {1..60}; do
    if curl -s http://localhost:$PORT/ready | grep -q "ready"; then
        echo "Service UP."
        break
    fi
    sleep 2
done

# Send same request - Expect 400
echo "INFO: Sending 500x500 request (Expect 400)..."
HTTP_CODE=$(curl -s -o "$OUTPUT_JSON" -w "%{http_code}" -X POST http://localhost:$PORT/v1/images/edits \
  -H "Authorization: Bearer mysecretkey" \
  -F "prompt=strict test" \
  -F "image=@$INPUT_IMG" \
  -F "strength=0.75" \
  -F "sync=true")

echo "HTTP Code: $HTTP_CODE"
cat "$OUTPUT_JSON"
echo ""

if [ "$HTTP_CODE" != "400" ]; then
    echo "FAIL: Expected 400, got $HTTP_CODE"
    exit 1
fi

# Check Error Envelope
CODE_VAL=$(cat "$OUTPUT_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('error', {}).get('code', ''))")
MSG_VAL=$(cat "$OUTPUT_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('error', {}).get('message', ''))")

echo "Error Code: $CODE_VAL"
echo "Error Message: $MSG_VAL"

if [ "$CODE_VAL" != "invalid_image_size" ]; then
    echo "FAIL: Error code mismatch. Expected 'invalid_image_size', got '$CODE_VAL'"
    exit 1
fi

if [[ "$MSG_VAL" != *"500x500"* ]]; then
    echo "FAIL: Error message missing dimensions"
    exit 1
fi

echo "PASS: Strict Mode Verified."

# Cleanup/Restart Normal
echo "INFO: Restoring normal service..."
pkill -f "start.sh" || true
pkill -f "uvicorn" || true
sleep 5
unset STRICT_IMAGE_SIZE
unset AUTO_RESIZE
nohup $ROOT/start.sh >/dev/null 2>&1 &
echo "Waiting for normal service..."
for i in {1..60}; do
    if curl -s http://localhost:$PORT/health | grep -q "ok"; then
        echo "Service restored."
        break
    fi
    sleep 2
done

echo "TEST SUITE COMPLETED"
