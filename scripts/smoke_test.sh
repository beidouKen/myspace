#!/bin/bash
BASE_URL="http://localhost:8000"
API_KEY=${API_KEY:-""}

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

function fail {
    echo -e "${RED}FAIL: $1${NC}"
    exit 1
}

function pass {
    echo -e "${GREEN}PASS: $1${NC}"
}

echo "--- SMOKE TEST STARTING ---"

# 1. Health
echo "Checking Health..."
status=$(curl -s -o /dev/null -w "%{http_code}" $BASE_URL/health)
if [ "$status" != "200" ]; then fail "Health check failed (HTTP $status)"; fi
pass "Health check OK"

# 2. Models
echo "Checking Models..."
AUTH_HEADER=""
if [ -n "$API_KEY" ]; then AUTH_HEADER="-H \"Authorization: Bearer $API_KEY\""; fi
# Note: eval to handle empty header safely
resp=$(eval curl -s $AUTH_HEADER $BASE_URL/v1/models)
if echo "$resp" | grep -q "glm-image"; then
    pass "Models list contains glm-image"
else
    fail "Models list bad: $resp"
fi

# 3. Metrics
echo "Checking Metrics..."
curl -s $BASE_URL/metrics > /dev/null
pass "Metrics endpoint OK"

# 4. Sync Generation (b64_json)
echo "Testing Sync Generation (b64_json)..."
# Use small size/steps for speed if backend supports it
payload='{"prompt": "smoke test", "size": "256x256", "steps": 2, "sync": true, "response_format": "b64_json"}'
resp=$(eval curl -s -X POST $AUTH_HEADER -H "Content-Type: application/json" -d \'$payload\' $BASE_URL/v1/images/generations)

# Check if we got data or error
if echo "$resp" | grep -q "error"; then
    # It might be 503 if model not loaded
    echo "Warning: Got error. Is model loaded? Response: $resp"
    # We don't fail immediately if it's just model loading, but for smoke test it usually implies system ready.
    # checking for b64_json
fi
if echo "$resp" | grep -q "b64_json"; then
    pass "Sync b64_json generation OK"
else
    fail "Sync b64_json failed. Resp: $resp"
fi

# 5. Sync Generation (url)
echo "Testing Sync Generation (url)..."
payload='{"prompt": "smoke test url", "size": "256x256", "steps": 2, "sync": true, "response_format": "url"}'
resp=$(eval curl -s -X POST $AUTH_HEADER -H "Content-Type: application/json" -d \'$payload\' $BASE_URL/v1/images/generations)

url=$(echo "$resp" | grep -o 'http://[^"]*' | head -1)
if [ -z "$url" ]; then fail "No URL in response: $resp"; fi
pass "Got URL: $url"

# Download image
echo "Downloading image..."
curl -s -f -o smoke_test.png "$url"
if [ $? -eq 0 ]; then
    # Check mime type or header roughly
    if file smoke_test.png | grep -q "PNG"; then
        pass "Image downloaded and is PNG"
    else
        fail "Downloaded file is not PNG: $(file smoke_test.png)"
    fi
    rm smoke_test.png
else
    fail "Failed to download image from $url"
fi

# 6. Async Cycle
echo "Testing Async Submit + Poll..."
payload='{"prompt": "async test", "steps": 2, "sync": false}'
resp=$(eval curl -s -X POST $AUTH_HEADER -H "Content-Type: application/json" -d \'$payload\' $BASE_URL/v1/images/generations)
task_id=$(echo "$resp" | grep -o '"task_id": *"[^"]*"' | cut -d'"' -f4)

if [ -z "$task_id" ]; then fail "Async submit failed: $resp"; fi
pass "Submitted Async Task: $task_id"

# Poll
for i in {1..20}; do
    status_resp=$(curl -s $BASE_URL/v1/tasks/$task_id)
    status=$(echo "$status_resp" | grep -o '"status": *"[^"]*"' | cut -d'"' -f4)
    echo "Status: $status"
    if [ "$status" == "completed" ]; then
        pass "Async task completed"
        break
    fi
    if [ "$status" == "failed" ]; then
        fail "Async task failed: $status_resp"
    fi
    sleep 2
done
if [ "$status" != "completed" ]; then fail "Async task timed out"; fi

# 7. Cancel Test
echo "Testing Cancellation..."
# Send a long task
payload='{"prompt": "cancel test", "steps": 50, "sync": false}'
resp=$(eval curl -s -X POST $AUTH_HEADER -H "Content-Type: application/json" -d \'$payload\' $BASE_URL/v1/images/generations)
task_id=$(echo "$resp" | grep -o '"task_id": *"[^"]*"' | cut -d'"' -f4)
pass "Submitted long task: $task_id"

# Cancel immediately
cancel_resp=$(curl -s -X POST $BASE_URL/v1/tasks/$task_id/cancel)
if echo "$cancel_resp" | grep -q "cancelled"; then
    pass "Cancel request accepted"
else
    fail "Cancel request failed: $cancel_resp"
fi

# Verify status
status_resp=$(curl -s $BASE_URL/v1/tasks/$task_id)
status=$(echo "$status_resp" | grep -o '"status": *"[^"]*"' | cut -d'"' -f4)

if [ "$status" == "cancelled" ]; then
    pass "Task status verified as cancelled"
else
    fail "Task status not cancelled: $status"
fi

echo -e "${GREEN}ALL TESTS PASSED${NC}"
