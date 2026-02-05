#!/bin/bash
# 10_sync_url.sh
# Usage: ./10_sync_url.sh
# Environment Variables: PROMPT (default: "sync url test"), STEPS (default: 2)

source "$(dirname "$0")/common.sh"
set -euo pipefail

PROMPT=${PROMPT:-"sync url test"}
STEPS=${STEPS:-2}

log "Running 10_sync_url.sh..."
log "Prompt: $PROMPT, Steps: $STEPS"

# Prepare payload
PAYLOAD=$(printf '{"prompt": "%s", "steps": %d, "sync": true, "response_format": "url", "size": "256x256"}' "$PROMPT" "$STEPS")

# Request
log "Sending POST /v1/images/generations..."
RESP=$($CURL_AUTH -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$BASE_URL/v1/images/generations")

# Save response
echo "$RESP" > "$OUT_DIR/sync_url_response.json"

# Check for error
ERR=$(get_json_value "$RESP" "['error']")
if [ -n "$ERR" ] && [ "$ERR" != "None" ]; then
    fail "API Error: $RESP"
fi

# Extract URL
URL=$(get_json_value "$RESP" "['data'][0]['url']")
log "Got URL: $URL"

if [ -z "$URL" ] || [ "$URL" == "None" ]; then
    fail "No URL found in response: $RESP"
fi

# Download Image
IMG_PATH="$OUT_DIR/sync_url.png"
log "Downloading to $IMG_PATH..."
if curl -s -f -o "$IMG_PATH" "$URL"; then
    pass "Download successful"
else
    fail "Download failed"
fi

# Validate PNG
FILE_INFO=$(file "$IMG_PATH")
SIZE=$(stat -c%s "$IMG_PATH" 2>/dev/null || stat -f%z "$IMG_PATH")

if [[ "$FILE_INFO" == *"PNG image data"* ]]; then
    pass "File validation OK: $FILE_INFO"
    log "Image Size: $SIZE bytes"
else
    fail "File validation failed: $FILE_INFO"
fi

pass "10_sync_url.sh completed successfully."
