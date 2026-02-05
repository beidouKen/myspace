#!/bin/bash
# 11_sync_b64.sh
# Usage: ./11_sync_b64.sh
# Environment Variables: PROMPT (default: "sync b64 test"), STEPS (default: 2)

source "$(dirname "$0")/common.sh"
set -euo pipefail

PROMPT=${PROMPT:-"sync b64 test"}
STEPS=${STEPS:-2}

log "Running 11_sync_b64.sh..."
log "Prompt: $PROMPT, Steps: $STEPS"

# Prepare payload
PAYLOAD=$(printf '{"prompt": "%s", "steps": %d, "sync": true, "response_format": "b64_json", "size": "256x256"}' "$PROMPT" "$STEPS")

# Request
log "Sending POST /v1/images/generations..."
RESP=$($CURL_AUTH -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$BASE_URL/v1/images/generations")

# Save response (Warning: might be large)
echo "$RESP" > "$OUT_DIR/sync_b64_response.json"

# Check for error
ERR=$(get_json_value "$RESP" "['error']")
if [ -n "$ERR" ] && [ "$ERR" != "None" ]; then
    fail "API Error: $RESP"
fi

# Extract b64_json
# Using python directly to decode without printing large string to log
log "Extracting and decoding base64..."
echo "$RESP" | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
b64 = data.get('data', [{}])[0].get('b64_json', '')
if not b64:
    sys.exit(1)
with open('$OUT_DIR/sync_b64.png', 'wb') as f:
    f.write(base64.b64decode(b64))
"

if [ $? -eq 0 ]; then
    pass "Base64 decoded successfully"
else
    fail "Failed to extract/decode b64_json"
fi

# Validate PNG
IMG_PATH="$OUT_DIR/sync_b64.png"
FILE_INFO=$(file "$IMG_PATH")
if [[ "$FILE_INFO" == *"PNG image data"* ]]; then
    pass "File validation OK: $FILE_INFO"
else
    fail "File validation failed: $FILE_INFO"
fi

pass "11_sync_b64.sh completed successfully."
