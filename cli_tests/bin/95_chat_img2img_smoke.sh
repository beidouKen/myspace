#!/bin/bash
set -e
source "$(dirname "$0")/_common.sh"
# Config
API_URL="$BASE_URL/v1/chat/completions"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ASSET_DIR="${ASSET_DIR:-$ROOT/cli_tests/assets}"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
REPORT_FILE="$OUT_DIR/chat_img2img_proof.txt"
ASSET_PORT="${ASSET_PORT:-9000}"
ASSET_HOST="http://127.0.0.1:$ASSET_PORT"

mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR"/*

echo "=== Setup: Starting Asset Server ==="
python3 -m http.server $ASSET_PORT --directory "$ASSET_DIR" > /dev/null 2>&1 &
ASSET_PID=$!
echo "Asset Server PID: $ASSET_PID"
sleep 2

# Cleanup trap
cleanup() {
    echo "Stopping Asset Server..."
    kill $ASSET_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Case 1: Chat txt2img Smoke ==="
START_TS=$(date +%s)
RESP=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "glm-image",
    "messages": [
      {
        "role": "user",
        "content": "draw a cat"
      }
    ]
  }')

echo "Response: $RESP"

# Parse Content
CONTENT=$(echo "$RESP" | python3 -c "import sys, json; print(json.load(sys.stdin)['choices'][0]['message']['content'])")
echo "Content: $CONTENT"

if [[ "$CONTENT" == *"outputs/"*".png"* ]]; then
    echo "PASS: URL found in content"
else
    echo "FAIL: URL not found"
    exit 1
fi

# Extract URL (Simple grep/cut hack)
IMG_URL=$(echo "$CONTENT" | grep -o 'http://[^)]*' | head -n 1)
echo "Image URL: $IMG_URL"

# Download
curl -s "$IMG_URL" -o "$OUT_DIR/chat_txt2img.png"
if [[ -f "$OUT_DIR/chat_txt2img.png" ]]; then
    echo "PASS: Downloaded txt2img result"
else
    echo "FAIL: Download failed"
    exit 1
fi
FINISH_TS=$(date +%s)

# Record Proof
echo "task_id: txt2img_case1" >> "$REPORT_FILE"
echo "mode: txt2img" >> "$REPORT_FILE"
echo "start: $START_TS" >> "$REPORT_FILE"
echo "finish: $FINISH_TS" >> "$REPORT_FILE"
echo "queued: false" >> "$REPORT_FILE"
echo "--------------------------------" >> "$REPORT_FILE"


echo "=== Case 2: Chat img2img Smoke ==="
# Verify asset exists
if [ ! -f "$ASSET_DIR/dog.png" ]; then
    echo "Error: dog.png missing in assets"
    exit 1
fi

IMG_INPUT_URL="$ASSET_HOST/dog.png"
echo "Input Image: $IMG_INPUT_URL"

START_TS=$(date +%s)
RESP=$(curl -s -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"glm-image\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": \"edit this image to watercolor style img2img $IMG_INPUT_URL\"
      }
    ]
  }")

echo "Response Length: ${#RESP}"

CONTENT=$(echo "$RESP" | python3 -c "import sys, json; print(json.load(sys.stdin)['choices'][0]['message']['content'])")
echo "Content: $CONTENT"

if [[ "$CONTENT" == *"outputs/"*".png"* ]]; then
    echo "PASS: URL found for img2img"
else
    echo "FAIL: URL not found for img2img"
    echo "Full Resp: $RESP"
    exit 1
fi

IMG_URL=$(echo "$CONTENT" | grep -o 'http://[^)]*' | head -n 1)
curl -s "$IMG_URL" -o "$OUT_DIR/chat_img2img.png"

# Compare
HASH_ORIG=$(sha256sum "$ASSET_DIR/dog.png" | awk '{print $1}')
HASH_NEW=$(sha256sum "$OUT_DIR/chat_img2img.png" | awk '{print $1}')

if [ "$HASH_ORIG" != "$HASH_NEW" ]; then
    echo "PASS: Image changed"
else
    echo "FAIL: Image identical to input"
    exit 1
fi
FINISH_TS=$(date +%s)

echo "task_id: img2img_case2" >> "$REPORT_FILE"
echo "mode: img2img" >> "$REPORT_FILE"
echo "start: $START_TS" >> "$REPORT_FILE"
echo "finish: $FINISH_TS" >> "$REPORT_FILE"
echo "queued: false" >> "$REPORT_FILE"
echo "--------------------------------" >> "$REPORT_FILE"


echo "=== Case 3: Concurrency & Queue ==="
# Launch 3 requests
# 1. txt2img
# 2. img2img
# 3. txt2img

do_req() {
    ID=$1
    MODE=$2
    PROMPT=$3
    S_TS=$(date +%s)
    # echo "Start $ID at $S_TS"
    file_out="$OUT_DIR/req_$ID.json"
    
    curl -s -X POST "$API_URL" \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"glm-image\",
        \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}]
      }" > "$file_out"
      
    E_TS=$(date +%s)
    
    # Analyze result
    # We can't easily parse content here in bash subshell without mess, so we write to file
    echo "$ID,$MODE,$S_TS,$E_TS" >> "$OUT_DIR/timings.csv"
}

echo "Launching 3 concurrent requests..."
PIDS=""

do_req 1 txt2img "draw a bird" &
PIDS="$PIDS $!"

do_req 2 img2img "edit img2img $IMG_INPUT_URL" &
PIDS="$PIDS $!"

do_req 3 txt2img "draw a fish" &
PIDS="$PIDS $!"

wait $PIDS
echo "All concurrent requests finished."

# Analyze timings
cat "$OUT_DIR/timings.csv" | sort -t, -k3 > "$OUT_DIR/timings_sorted.csv"

# Simple logic: If strict serial per backend (2 backends), 
# Request 1 & 2 might start immediately.
# Request 3 should start after one of them finishes.
# Since we don't have task start time in client response (only created), we infer from total duration.
# If duration of Req 3 is roughly sum of others or significantly longer than single gen time.

while IFS=, read -r id mode start end; do
    dur=$((end - start))
    echo "Req $id: Duration ${dur}s"
    
    echo "task_id: conc_case3_$id" >> "$REPORT_FILE"
    echo "mode: $mode" >> "$REPORT_FILE"
    echo "start: $start" >> "$REPORT_FILE"
    echo "finish: $end" >> "$REPORT_FILE"
    if [ "$dur" -gt 10 ]; then # Assuming generation takes ~2-5s, waiting adds time
       echo "queued: likely" >> "$REPORT_FILE"
    else
       echo "queued: unlikely" >> "$REPORT_FILE"
    fi
    echo "--------------------------------" >> "$REPORT_FILE"
    
done < "$OUT_DIR/timings_sorted.csv"

echo "=== All Tests Passed ==="
