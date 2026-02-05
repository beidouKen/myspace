#!/bin/bash
set -e
source "$(dirname "$0")/_common.sh"
echo "Testing Chat Adapter on $BASE_URL ..."

# 1. Simple txt2img
echo "[TEST] txt2img via /v1/chat/completions"
RESP=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "a futuristic city size=512x512 steps=20"}
    ]
  }')

# Check structure
echo "Response: $RESP"
if echo "$RESP" | grep -q '"object": *"chat.completion"'; then
    echo "✅ Response structure valid"
else
    echo "❌ Response structure invalid"
    exit 1
fi

# Extract URL (simple grep/sed as jq might not be available, or python)
IMG_URL=$(echo "$RESP" | grep -o 'http[^)]*\.png' | head -n 1)
echo "Extracted URL: $IMG_URL"

if [ -z "$IMG_URL" ]; then
   echo "❌ No Image URL found in Markdown"
   exit 1
fi

# Download
curl -s "$IMG_URL" -o test_chat_out.png
if file test_chat_out.png | grep -q "PNG image data"; then
    echo "✅ Image downloaded and is PNG"
else
    echo "❌ Downloaded file is not PNG"
    exit 1
fi
rm test_chat_out.png

# 2. Stream=true (Compatibility Test)
echo "[TEST] stream=true request (Should be handled as non-stream)"
RESP_STREAM=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {"role": "user", "content": "a futuristic car size=512x512"}
    ],
    "stream": true
  }')

# Check structure
echo "Response (Stream req): $RESP_STREAM"
if echo "$RESP_STREAM" | grep -q '"object": *"chat.completion"'; then
    echo "✅ Response structure valid (despite stream=true)"
else
    echo "❌ Response structure invalid"
    exit 1
fi

IMG_URL_S=$(echo "$RESP_STREAM" | grep -o 'http[^)]*\.png' | head -n 1)
if [ -z "$IMG_URL_S" ]; then
   echo "❌ No Image URL found in Markdown (Stream case)"
   exit 1
fi

# Download
curl -s "$IMG_URL_S" -o test_stream_out.png
if file test_stream_out.png | grep -q "PNG image data"; then
    echo "✅ Image downloaded and is PNG (Stream case)"
else
    echo "❌ Downloaded file is not PNG (Stream case)"
    exit 1
fi
rm test_stream_out.png

echo "ALL TESTS PASSED"
