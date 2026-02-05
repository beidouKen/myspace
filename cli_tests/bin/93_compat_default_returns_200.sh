#!/bin/bash
# 93_compat_default_returns_200.sh
# Gate: 默认 compat 模式 — IMAGES/CHAT_SYNC_WAIT_TIMEOUT_SEC=300，请求在阈值内完成，断言 200 + 图片 url（无 202）。

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
PROOF_FILE="$OUT_DIR/proof_93.txt"
API_KEY="${API_KEY:-mysecretkey}"
IMAGES_TIMEOUT="${IMAGES_SYNC_WAIT_TIMEOUT_SEC:-300}"
CHAT_TIMEOUT="${CHAT_SYNC_WAIT_TIMEOUT_SEC:-300}"

mkdir -p "$OUT_DIR" "$(dirname "$LOG_DIR")"
: > "$PROOF_FILE"

echo "=== 93 Compat Default Returns 200 Gate ===" | tee -a "$PROOF_FILE"
echo "BASE_URL=$BASE_URL" | tee -a "$PROOF_FILE"
echo "IMAGES_SYNC_WAIT_TIMEOUT_SEC=$IMAGES_TIMEOUT CHAT_SYNC_WAIT_TIMEOUT_SEC=$CHAT_TIMEOUT" | tee -a "$PROOF_FILE"

if ! curl -s --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; then
    echo "Starting service with compat timeouts (300s)..." | tee -a "$PROOF_FILE"
    export IMAGES_SYNC_WAIT_TIMEOUT_SEC=300
    export CHAT_SYNC_WAIT_TIMEOUT_SEC=300
    nohup "$ROOT/start.sh" >> "$LOG_DIR/start_93.log" 2>&1 &
    for i in $(seq 1 60); do
        if curl -s "$BASE_URL/ready" 2>/dev/null | grep -q "ready"; then
            echo "Service ready."
            break
        fi
        sleep 2
    done
fi

if ! curl -s --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; then
    echo "FAIL: Service not available at $BASE_URL" | tee -a "$PROOF_FILE"
    exit 1
fi

# 1) Chat completions 图片请求（较快：512x512 steps=20，在 300s 内完成）
CHAT_BODY='{"model":"glm-image","messages":[{"role":"user","content":"a red apple size=512x512 steps=20"}]}'
echo "" | tee -a "$PROOF_FILE"
echo "--- Request 1: POST /v1/chat/completions (no prefer_async) ---" | tee -a "$PROOF_FILE"

HTTP_CHAT=$(curl -s -o "$OUT_DIR/chat_93.json" -w "%{http_code}" -X POST "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$CHAT_BODY")

echo "HTTP status: $HTTP_CHAT" | tee -a "$PROOF_FILE"
if [ "$HTTP_CHAT" != "200" ]; then
    echo "FAIL: Expected 200 for chat/completions (compat default), got $HTTP_CHAT" | tee -a "$PROOF_FILE"
    cat "$OUT_DIR/chat_93.json" >> "$PROOF_FILE"
    exit 1
fi
# 断言含可渲染图片 url
if ! grep -q 'http.*\.png\|outputs/.*\.png' "$OUT_DIR/chat_93.json" 2>/dev/null; then
    echo "FAIL: Chat response has no image url" | tee -a "$PROOF_FILE"
    cat "$OUT_DIR/chat_93.json" >> "$PROOF_FILE"
    exit 1
fi
echo "PASS: Chat/completions returned 200 with image url." | tee -a "$PROOF_FILE"

# 2) Images txt2img（512x512 steps=20，sync 默认）
IMG_BODY='{"prompt":"a blue sky","size":"512x512","steps":20,"sync":true}'
echo "" | tee -a "$PROOF_FILE"
echo "--- Request 2: POST /v1/images/generations (sync=true, no prefer_async) ---" | tee -a "$PROOF_FILE"

HTTP_IMG=$(curl -s -o "$OUT_DIR/img_93.json" -w "%{http_code}" -X POST "$BASE_URL/v1/images/generations" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$IMG_BODY")

echo "HTTP status: $HTTP_IMG" | tee -a "$PROOF_FILE"
if [ "$HTTP_IMG" != "200" ]; then
    echo "FAIL: Expected 200 for images/generations (compat default), got $HTTP_IMG" | tee -a "$PROOF_FILE"
    cat "$OUT_DIR/img_93.json" >> "$PROOF_FILE"
    exit 1
fi
if ! grep -q '"url"\s*:\s*"http\|"b64_json"' "$OUT_DIR/img_93.json" 2>/dev/null; then
    echo "FAIL: Images response has no url/b64_json" | tee -a "$PROOF_FILE"
    cat "$OUT_DIR/img_93.json" >> "$PROOF_FILE"
    exit 1
fi
echo "PASS: Images/generations returned 200 with image data." | tee -a "$PROOF_FILE"

echo "" | tee -a "$PROOF_FILE"
echo "=== Gate 93 PASS ===" | tee -a "$PROOF_FILE"
echo "Proof written to: $PROOF_FILE"
