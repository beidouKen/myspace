#!/bin/bash
set -e
# 99_idempotency_smoke.sh
source "$(dirname "$0")/_common.sh"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_FILE="${OUT_DIR:-$ROOT/cli_tests/out}/idempotency_proof.txt"
mkdir -p "$(dirname "$OUT_FILE")"
rm -f "$OUT_FILE"
API_URL="$BASE_URL/v1/images/generations"

IDEM_KEY="test-key-$(date +%s)"
echo "Using Idempotency-Key: $IDEM_KEY"

# 1. First Request
echo "Req 1..."
RESP1=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: $IDEM_KEY" \
    -d '{ "prompt": "idempotency test" }')
echo "Resp1: $RESP1" >> "$OUT_FILE"
TASK_ID1=$(echo "$RESP1" | python3 -c "import sys, json; print(json.load(sys.stdin).get('task_id'))")

# 2. Second Request
echo "Req 2 (Immediate duplicate)..."
RESP2=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: $IDEM_KEY" \
    -d '{ "prompt": "idempotency test" }')
echo "Resp2: $RESP2" >> "$OUT_FILE"
TASK_ID2=$(echo "$RESP2" | python3 -c "import sys, json; print(json.load(sys.stdin).get('task_id'))")

if [ "$TASK_ID1" == "$TASK_ID2" ] && [ -n "$TASK_ID1" ]; then
    echo "PASS: Task IDs match ($TASK_ID1)" >> "$OUT_FILE"
    echo "PASS: Idempotency Logic Verified"
else
    echo "FAIL: Task IDs mismatch ($TASK_ID1 vs $TASK_ID2)"
    exit 1
fi
