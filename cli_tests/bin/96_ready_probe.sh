#!/bin/bash
set -e
# 96_ready_probe.sh: Check /ready endpoint
source "$(dirname "$0")/_common.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
mkdir -p "$OUT_DIR"
API_URL="$BASE_URL/ready"

echo "Checking /ready..."

# Loop for a bit to allow startup if run immediately
MAX_RETRIES=10
for i in $(seq 1 $MAX_RETRIES); do
    STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL")
    if [ "$STATUS_CODE" == "200" ]; then
        echo "PASS: /ready returned 200"
        curl -s "$API_URL" > "$OUT_DIR/ready_probe.json"
        cat "$OUT_DIR/ready_probe.json"
        exit 0
    else
        echo "Wait... ($i/$MAX_RETRIES) Code: $STATUS_CODE"
        sleep 2
    fi
done

echo "FAIL: /ready did not become 200"
exit 1
