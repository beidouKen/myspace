#!/bin/bash
# Aggregate smoke: healthz -> readyz -> models -> txt2img -> img2img. Exit non-zero on first failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/bin"
OUT_DIR="${OUT_DIR:-$ROOT/out}"
mkdir -p "$OUT_DIR"
source "$BIN/_common.sh"

run() {
    echo "--- $1 ---"
    local tmp="$OUT_DIR/.smoke_$$_$1"
    if ! curl -sS --fail --max-time 10 "$BASE_URL/$1" -o "$tmp"; then
        echo "FAIL: $1" >&2
        exit 1
    fi
    head -c 500 "$tmp"
    rm -f "$tmp"
    echo ""
}

# 1. healthz
run healthz

# 2. readyz
run readyz

# 3. v1/models
echo "--- v1/models ---"
TMP="$OUT_DIR/.smoke_models.json"
curl -sS --fail --max-time 10 "$BASE_URL/v1/models" -o "$TMP" || { echo "FAIL: v1/models"; exit 1; }
head -c 500 "$TMP"
rm -f "$TMP"
echo ""

# 4. txt2img (sync, minimal steps) - write to temp to avoid pipe break on large body
TMP_TXT2IMG="$OUT_DIR/.smoke_txt2img.json"
curl -sS --fail --max-time 120 -X POST "$BASE_URL/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"a red apple","n":1,"size":"512x512","steps":25,"sync":true}' -o "$TMP_TXT2IMG" || { echo "FAIL: txt2img"; exit 1; }
echo "--- txt2img ---"
echo "OK ($(head -c 80 "$TMP_TXT2IMG")...)"
rm -f "$TMP_TXT2IMG"

# 5. img2img
TMP_IMG2IMG="$OUT_DIR/.smoke_img2img.json"
curl -sS --fail --max-time 120 -X POST "$BASE_URL/v1/images/edits" \
  -F "image=@$ROOT/assets/dog.png" \
  -F "prompt=watercolor" -F "n=1" -F "size=512x512" -F "steps=25" -o "$TMP_IMG2IMG" || { echo "FAIL: img2img"; exit 1; }
echo "--- img2img ---"
echo "OK ($(head -c 80 "$TMP_IMG2IMG")...)"
rm -f "$TMP_IMG2IMG"

echo "--- smoke OK ---"
