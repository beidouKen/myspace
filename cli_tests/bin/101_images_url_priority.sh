#!/bin/bash
set -e
# 101_images_url_priority.sh: images response url-first, url downloadable

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
mkdir -p "$OUT_DIR"
PROOF="$OUT_DIR/101_images_url_priority_proof.txt"
IMG_FILE="$OUT_DIR/101_downloaded.png"
rm -f "$PROOF" "$IMG_FILE"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$PROOF"; }
pass() { echo "PASS: $*" | tee -a "$PROOF"; }
fail() { echo "FAIL: $*" | tee -a "$PROOF"; exit 1; }

log "101_images_url_priority.sh: images response url-first, url downloadable"

RESP=$(curl -s -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "a red apple", "steps": 4, "sync": true, "response_format": "url", "size": "512x512"}')

echo "$RESP" >> "$PROOF"

# Check url present (url-first: prefer url over b64)
URL=$(echo "$RESP" | python3 -c "import sys, json; d=json.load(sys.stdin); print(d.get('data', [{}])[0].get('url') or '')" 2>/dev/null || echo "")
if [ -z "$URL" ]; then
  fail "data[0].url missing: $RESP"
fi
pass "data[0].url present: $URL"

# Download
if ! curl -sSf -o "$IMG_FILE" "$URL"; then
  fail "url not downloadable via curl"
fi
pass "url downloadable via curl"

if ! file "$IMG_FILE" | grep -q "PNG image data"; then
  fail "downloaded file is not PNG"
fi
pass "downloaded file is PNG"

pass "101_images_url_priority.sh completed successfully."
