#!/bin/bash
# 85_img2img_validation.sh
# Comprehensive validation of Gateway image preprocessing rules.
#
# Rules:
# 1. RGB conversion
# 2. Scale down to MAX_SIDE (preserving aspect) if > MAX_SIDE
# 3. Pad to REQUIRE_MULTIPLE
# 4. Strict Mode rejects non-compliant

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
LOG_DIR="$ROOT/logs"
GATEWAY_LOG="$LOG_DIR/gateway.log"
PROOF_FILE="$OUT_DIR/proof_85.txt"
PORT=8000

mkdir -p "$OUT_DIR"
rm -f "$PROOF_FILE"

# --- Utils ---
wait_for_service() {
    echo "Waiting for service at port $PORT..."
    for i in {1..60}; do
        # Must match "status":"ready" strictly, avoiding "status":"not_ready"
        if curl -s http://localhost:$PORT/ready | grep -q '"status":"ready"'; then
            echo "Service UP and READY."
            return 0
        fi
        echo "Waiting for readiness... ($i/60)"
        sleep 2
    done
    echo "Service failed to come up."
    return 1
}

# --- 1. Preparation ---
echo "INFO: Generating test images..."
python3 -c "from PIL import Image
def gen(w, h, name):
    Image.new('RGB', (w, h), (128,128,128)).save(f'$OUT_DIR/{name}')
    print(f'Generated {name} ({w}x{h})')

gen(500, 500, 'test_500x500.png')
gen(800, 600, 'test_800x600.png')
gen(1200, 2400, 'test_1200x2400.png')
gen(3000, 500, 'test_3000x500.png')
gen(1024, 1024, 'test_1024x1024.png')
"

# Check if service is running normal mode
if ! curl -s http://localhost:$PORT/health | grep -q "ok"; then
    echo "INFO: Service not running. Starting normal mode..."
    nohup $ROOT/start.sh > /dev/null 2>&1 &
    wait_for_service
fi

# --- 2. Validation Loop (Normal Mode) ---
echo "---------------------------------------------------"
echo "[TEST] Normal Mode Validation (AUTO_RESIZE=1)"
echo "---------------------------------------------------"

check_image() {
    local img_name=$1
    local expected_w=$2
    local expected_h=$3
    local case_desc=$4

    echo "CASE: $case_desc ($img_name)"
    local input_path="$OUT_DIR/$img_name"
    local output_json="$OUT_DIR/resp_${img_name}.json"
    
    # Send Request
    curl -s --retry 10 --retry-delay 5 --retry-connrefused -X POST http://localhost:$PORT/v1/images/edits \
      -H "Authorization: Bearer mysecretkey" \
      -F "prompt=validation" \
      -F "image=@$input_path" \
      -F "sync=true" \
      -F "response_format=url" \
      > "$output_json"
      
    # Check 200
    if grep -q "error" "$output_json"; then
        echo "FAIL: API Error for $img_name"
        cat "$output_json"
        return 1
    fi
    
    # Check Log
    sleep 1
    # Look for last PREPROCESS_IMAGE log - BUT we need to be careful about concurrency if multiple requests ran.
    # We should really filter by task_id, but the response only has URL which contains task_id.
    
    # Extract Task ID from Output JSON URL
    local url=$(cat "$output_json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data', [{}])[0].get('url', ''))")
    
    if [ -z "$url" ] || [ "$url" == "None" ]; then
        echo "FAIL: No URL in response"
        cat "$output_json"
        return 1
    fi
    
    local task_id=$(echo "$url" | awk -F'/' '{print $NF}' | sed 's/\.png//')
    
    echo "  -> Task ID: $task_id"
    
    # Wait for logs to flush
    sleep 2
    
    local log_line=$(grep "PREPROCESS_IMAGE" "$GATEWAY_LOG" | grep "$task_id" | tail -n 1)
    
    if [ -z "$log_line" ]; then
        echo "FAIL: No PREPROCESS_IMAGE log found for $task_id"
        return 1
    fi
    
    # Extract final_size from JSON log
    local final_size=$(echo "$log_line" | python3 -c "import sys, json; print(json.load(sys.stdin).get('final_size', ''))")
    local action=$(echo "$log_line" | python3 -c "import sys, json; print(json.load(sys.stdin).get('action', ''))")
    local mode=$(echo "$log_line" | python3 -c "import sys, json; print(json.load(sys.stdin).get('mode', ''))")
    
    echo "  -> Log: $final_size, Action: $action, Mode: $mode"
    
    if [ "$final_size" != "${expected_w}x${expected_h}" ]; then
        echo "FAIL: Size mismatch. Expected ${expected_w}x${expected_h}, got $final_size"
        return 1
    fi
    
    if [ "$action" != "resized_padded" ] && [ "$img_name" != "test_1024x1024.png" ]; then
         echo "FAIL: Action mismatch. Expected resized_padded"
         return 1
    fi
    
    if [ "$img_name" == "test_1024x1024.png" ] && [ "$action" != "passthrough" ]; then
         echo "FAIL: Action mismatch for 1024x1024. Expected passthrough"
         return 1
    fi

    # Append to proof
    echo "PASS: $case_desc"
    echo "CASE: $case_desc | Input: $img_name | Expected: ${expected_w}x${expected_h} | Actual: $final_size | Action: $action" >> "$PROOF_FILE"
}

# 500x500 -> 512x512
check_image "test_500x500.png" 512 512 "Small Square"

# 800x600 -> 832x640
# 800/64 = 12.5 -> 13*64=832. 600/64=9.375 -> 10*64=640.
check_image "test_800x600.png" 832 640 "Standard Rect"

# 1200x2400 -> Scale down to max 1024.
# 2400 > 1024. Scale = 1024/2400 = 0.42666.
# W = 1200 * 0.42666 = 512.
# H = 1024.
# Final 512x1024.
check_image "test_1200x2400.png" 512 1024 "Large Portrait"

# 3000x500 -> Scale down to max 1024.
# 3000 > 1024. Scale = 1024/3000 = 0.34133.
# W = 1024.
# H = 500 * 0.34133 = 170.66.
# Pad H -> ceil(170.66/64)*64 = 3*64 = 192.
# Final 1024x192.
check_image "test_3000x500.png" 1024 192 "Large Landscape Strip"

# 1024x1024 -> 1024x1024 (Passthrough)
check_image "test_1024x1024.png" 1024 1024 "Perfect Fit"

echo "Normal Mode Tests Passed."

# --- 3. Strict Mode Validation ---
echo "---------------------------------------------------"
echo "[TEST] Strict Mode Validation (STRICT_IMAGE_SIZE=1)"
echo "---------------------------------------------------"

echo "Restarting service in Strict Mode..."
pkill -f "start.sh" || true
pkill -f "uvicorn" || true
wait || true
sleep 3

export STRICT_IMAGE_SIZE=1
export AUTO_RESIZE=0
nohup $ROOT/start.sh > "$LOG_DIR/start_strict_85.log" 2>&1 &
wait_for_service

# Test 800x600 (Should fail)
echo "Sending 800x600 (Expect 400)..."
HTTP_CODE=$(curl -s --retry 10 --retry-delay 5 --retry-connrefused -o "$OUT_DIR/resp_strict_fail.json" -w "%{http_code}" -X POST http://localhost:$PORT/v1/images/edits \
  -H "Authorization: Bearer mysecretkey" \
  -F "prompt=strict" \
  -F "image=@$OUT_DIR/test_800x600.png" \
  -F "sync=true")

echo "HTTP Code: $HTTP_CODE"
if [ "$HTTP_CODE" != "400" ]; then
    echo "FAIL: Expected 400 in strict mode, got $HTTP_CODE"
    exit 1
fi

CODE_VAL=$(cat "$OUT_DIR/resp_strict_fail.json" | python3 -c "import sys, json; print(json.load(sys.stdin).get('error', {}).get('code', ''))")
if [ "$CODE_VAL" != "invalid_image_size" ]; then
    echo "FAIL: Expected error code invalid_image_size, got $CODE_VAL"
    exit 1
fi
echo "PASS: Strict Mode Rejected Invalid Input"
echo "STRICT MODE CHECK: 800x600 -> 400 invalid_image_size" >> "$PROOF_FILE"

# Cleanup
echo "Cleaning up..."
pkill -f "start.sh" || true
pkill -f "uvicorn" || true
unset STRICT_IMAGE_SIZE
unset AUTO_RESIZE
sleep 2
nohup $ROOT/start.sh > /dev/null 2>&1 &
wait_for_service

echo "ALL VALIDATION TESTS PASSED."
