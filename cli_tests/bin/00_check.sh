#!/bin/bash
# 00_check.sh
# Usage: ./00_check.sh
# Description: Checks ports and basic health/models/metrics endpoints.

source "$(dirname "$0")/common.sh"
set -euo pipefail

log "Running 00_check.sh..."

# 1. Check Ports
log "Checking ports 8000, 8001, 8002..."
PORTS_OK=true
# ss might not be available in minimal envs, try curl check preferentially, but use ss if asked
if command -v ss &> /dev/null; then
    for port in 8000 8001 8002; do
        if ss -lntp | grep -q ":$port "; then
            pass "Port $port is listening"
        else
            echo "Warning: Port $port not found via ss"
            # Don't fail immediately, maybe backend count differs
        fi
    done
fi

# 2. GET /health
log "GET /health"
RESP=$($CURL_AUTH "$BASE_URL/health")
echo "$RESP" > "$OUT_DIR/check_health.json"
STATUS=$(get_json_value "$RESP" "['status']")

if [ "$STATUS" == "ok" ]; then
    pass "/health returned status: ok"
else
    fail "/health returned unexpected: $RESP"
fi

# 3. GET /v1/models
log "GET /v1/models"
RESP=$($CURL_AUTH "$BASE_URL/v1/models")
echo "$RESP" > "$OUT_DIR/check_models.json"
MODEL_ID=$(get_json_value "$RESP" "['data'][0]['id']")

if [[ "$MODEL_ID" == *"glm-image"* ]]; then
    pass "/v1/models contains glm-image"
else
    fail "/v1/models unexpected: $RESP"
fi

# 4. GET /metrics
log "GET /metrics"
RESP=$($CURL_AUTH "$BASE_URL/metrics")
echo "$RESP" > "$OUT_DIR/check_metrics.json"

QUEUE_LEN=$(get_json_value "$RESP" "['queue_length']")
# Assuming queue length is a number (could be 0)
if [[ "$QUEUE_LEN" =~ ^[0-9]+$ ]]; then
    pass "/metrics returned queue_length: $QUEUE_LEN"
else
    fail "/metrics returned invalid/no queue_length: $RESP"
fi

pass "00_check.sh completed successfully."
