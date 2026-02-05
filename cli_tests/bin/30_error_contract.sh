#!/bin/bash
# Stage3 error contract: four fixed error cases, output to cli_tests/out/stage3_error_contract.txt
# (a) txt2img steps out of range → 400 param=steps
# (b) txt2img size invalid → 400
# (c) edits missing image → 400 message "Missing required field: image" param=image
# (d) edits bad image (non-image file) → 400 param=image

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT_FILE="$OUT_DIR/stage3_error_contract.txt"
source "$BIN/_common.sh"

mkdir -p "$OUT_DIR"

run_ts=$(date -Iseconds)
echo "=== stage3_error_contract $run_ts BASE_URL=$BASE_URL ===" | tee "$OUT_FILE"
echo "" | tee -a "$OUT_FILE"

# (a) txt2img steps=-1 → 400, param=steps
echo "--- (a) txt2img steps 非法（steps=-1）---" | tee -a "$OUT_FILE"
resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"a red apple","n":1,"size":"512x512","steps":-1,"sync":true}' 2>/dev/null || true)
body=$(echo "$resp" | head -n -1)
code=$(echo "$resp" | tail -n 1)
echo "HTTP $code" | tee -a "$OUT_FILE"
echo "$body" | head -c 500 | tee -a "$OUT_FILE"
echo "" | tee -a "$OUT_FILE"
if echo "$body" | grep -q '"param":"steps"'; then
  echo "(OK: param=steps)" | tee -a "$OUT_FILE"
else
  echo "(FAIL: expected param=steps in body)" | tee -a "$OUT_FILE"
fi
echo "" | tee -a "$OUT_FILE"

# (b) txt2img size=123x456 → 400
echo "--- (b) txt2img size 非法（123x456）---" | tee -a "$OUT_FILE"
resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"a red apple","n":1,"size":"123x456","sync":true}' 2>/dev/null || true)
body=$(echo "$resp" | head -n -1)
code=$(echo "$resp" | tail -n 1)
echo "HTTP $code" | tee -a "$OUT_FILE"
echo "$body" | head -c 500 | tee -a "$OUT_FILE"
echo "" | tee -a "$OUT_FILE"
echo "" | tee -a "$OUT_FILE"

# (c) edits 缺 image → 400, message "Missing required field: image", param=image
echo "--- (c) edits 缺 image ---" | tee -a "$OUT_FILE"
resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -F "prompt=watercolor" -F "n=1" -F "size=512x512" 2>/dev/null || true)
body=$(echo "$resp" | head -n -1)
code=$(echo "$resp" | tail -n 1)
echo "HTTP $code" | tee -a "$OUT_FILE"
echo "$body" | head -c 500 | tee -a "$OUT_FILE"
echo "" | tee -a "$OUT_FILE"
if echo "$body" | grep -q 'Missing required field: image' && echo "$body" | grep -q '"param":"image"'; then
  echo "(OK: message + param=image)" | tee -a "$OUT_FILE"
else
  echo "(CHECK: expected message 'Missing required field: image' and param=image)" | tee -a "$OUT_FILE"
fi
echo "" | tee -a "$OUT_FILE"

# (d) edits 坏图（txt 伪装 png）→ 400, param=image
echo "--- (d) edits 传坏文件（txt 伪装 png）---" | tee -a "$OUT_FILE"
bad_file="$OUT_DIR/.bad_image_30.txt"
echo "not an image" > "$bad_file"
resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -F "prompt=watercolor" -F "image=@$bad_file" -F "n=1" -F "size=512x512" 2>/dev/null || true)
body=$(echo "$resp" | head -n -1)
code=$(echo "$resp" | tail -n 1)
echo "HTTP $code" | tee -a "$OUT_FILE"
echo "$body" | head -c 500 | tee -a "$OUT_FILE"
echo "" | tee -a "$OUT_FILE"
if echo "$body" | grep -q '"param":"image"'; then
  echo "(OK: param=image, 400 at gateway)" | tee -a "$OUT_FILE"
else
  echo "(CHECK: expected 400 with param=image)" | tee -a "$OUT_FILE"
fi
rm -f "$bad_file"
echo "" | tee -a "$OUT_FILE"

echo "=== end stage3_error_contract ===" | tee -a "$OUT_FILE"
