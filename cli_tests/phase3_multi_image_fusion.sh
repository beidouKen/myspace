#!/bin/bash
# phase3_multi_image_fusion.sh: Phase 3 多图融合 + n 张输出验收（轻量参数语义验收）
# 上传 2 张图片（同名 image 两次），n=2；steps/size 用轻量值以稳定通过，不压测性能
# 断言：HTTP 200、data.length==2、两条 url curl -I 200
# 输出: cli_tests/out/phase3_multi_image_fusion.txt

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT="$(mkdir -p "$OUT" && cd "$ROOT" && realpath "$OUT")"
OUT_FILE="$OUT/phase3_multi_image_fusion.txt"
BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
PHASE3_STEPS="${PHASE3_STEPS:-20}"
PHASE3_SIZE="${PHASE3_SIZE:-512x512}"
ASSETS="$ROOT/cli_tests/assets"

rm -f "$OUT_FILE"
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$OUT_FILE"; }
pass() { echo "PASS: $*" | tee -a "$OUT_FILE"; }
fail() { echo "FAIL: $*" | tee -a "$OUT_FILE"; exit 1; }

log "=== Phase 3 multi-image fusion: 2 images (same name), n=2 -> data.length==2, 2 URLs 200 ==="
log "BASE_URL=$BASE_URL OUT=$OUT_FILE"
log ""

# 准备 2 张图（同名 image 两次）
IMG="$ASSETS/dog.png"
if [ ! -f "$IMG" ]; then
  python3 -c "from PIL import Image; Image.new('RGB', (64,64), color='red').save('$OUT/phase3_img1.png'); Image.new('RGB', (64,64), color='blue').save('$OUT/phase3_img2.png')"
  IMG1="$OUT/phase3_img1.png"
  IMG2="$OUT/phase3_img2.png"
else
  IMG1="$IMG"
  IMG2="$IMG"
fi

log "--- 1. POST /v1/images/edits: 2 images (image x2), n=2, sync, url (light params: steps=$PHASE3_STEPS, size=$PHASE3_SIZE) ---"
RESP=$(curl -sS --max-time 300 -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/edits" \
  -F "prompt=Phase3 fusion test" \
  -F "image=@$IMG1" \
  -F "image=@$IMG2" \
  -F "n=2" \
  -F "steps=$PHASE3_STEPS" \
  -F "size=$PHASE3_SIZE" \
  -F "sync=true" \
  -F "response_format=url")
BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)
echo "$BODY" >> "$OUT_FILE"

if [ "$CODE" != "200" ]; then
  fail "Expected HTTP 200, got $CODE. Body: $BODY"
fi
pass "HTTP 200"

LEN=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data', [])))" 2>/dev/null || echo "0")
if [ "$LEN" != "2" ]; then
  fail "Expected data.length==2, got $LEN"
fi
pass "data.length==2"

log ""
log "--- 2. Two output URLs, curl -I 200 ---"
URLS=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
data = d.get('data', [])
u1 = data[0].get('url', '') if len(data) > 0 else ''
u2 = data[1].get('url', '') if len(data) > 1 else ''
print(u1)
print(u2)
" 2>/dev/null)
URL_1=$(echo "$URLS" | sed -n '1p')
URL_2=$(echo "$URLS" | sed -n '2p')
log "  url_1=$URL_1"
log "  url_2=$URL_2"
echo "url_1=$URL_1" >> "$OUT_FILE"
echo "url_2=$URL_2" >> "$OUT_FILE"

if [ -z "$URL_1" ] || [ -z "$URL_2" ]; then
  fail "Missing url in data[0] or data[1]"
fi

CODE_1=$(curl -sS -o /dev/null -w "%{http_code}" -I --max-time 10 "$URL_1" 2>/dev/null || echo "000")
CODE_2=$(curl -sS -o /dev/null -w "%{http_code}" -I --max-time 10 "$URL_2" 2>/dev/null || echo "000")
log "  url_1 -> HTTP $CODE_1"
log "  url_2 -> HTTP $CODE_2"

[ "$CODE_1" != "200" ] && fail "url_1 returned $CODE_1 (expected 200)"
[ "$CODE_2" != "200" ] && fail "url_2 returned $CODE_2 (expected 200)"
pass "Both output URLs return 200"

log ""
log "=== Phase 3 phase3_multi_image_fusion.sh: ALL PASS ==="
log "Output: $OUT_FILE"
exit 0
