#!/bin/bash
# Stage4 queue 429 repro script with concurrent txt2img requests.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
N="${N:-8}"
QUEUE_SIZE="${QUEUE_SIZE:-1}"

mkdir -p "$OUT_DIR/queue429"

echo "=== stage4_queue429 ==="
echo "BASE_URL=$BASE_URL"
echo "N=$N"
echo "QUEUE_SIZE=$QUEUE_SIZE"
echo ""
echo "操作步骤："
echo "1) 先停服务"
echo "2) 用更小队列重启："
echo "   QUEUE_SIZE=$QUEUE_SIZE nohup ./start.sh > logs/restart_queue1.log 2>&1 &"
echo "3) 再运行本脚本："
echo "   BASE_URL=$BASE_URL bash cli_tests/bin/41_queue_429.sh | tee cli_tests/out/stage4_queue429.txt"
echo ""

if ! curl -sS --fail --max-time 5 "$BASE_URL/healthz" >/dev/null; then
  echo "FAIL: /healthz 不可用"
  exit 1
fi

run_request() {
  local idx="$1"
  local out_file="$OUT_DIR/queue429/raw_${idx}.txt"
  local ts
  ts=$(date -Iseconds)
  local resp body code
  resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/generations" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\":\"queue429-$idx\",\"n\":1,\"size\":\"512x512\",\"steps\":25,\"sync\":true}" 2>/dev/null || true)
  body=$(echo "$resp" | sed '$d')
  code=$(echo "$resp" | tail -n 1)
  {
    echo "timestamp=$ts"
    echo "status=$code"
    echo "body_200=$(echo "$body" | head -c 200)"
  } > "$out_file"
}

echo "并发发起 $N 个 txt2img 请求..."
pids=()
for i in $(seq 1 "$N"); do
  run_request "$i" &
  pids+=("$!")
done

for pid in "${pids[@]}"; do
  wait "$pid"
done

count_200=0
count_429=0
count_other=0

for i in $(seq 1 "$N"); do
  code=$(sed -n 's/^status=//p' "$OUT_DIR/queue429/raw_${i}.txt" | head -n 1)
  if [[ "$code" == "200" ]]; then
    count_200=$((count_200 + 1))
  elif [[ "$code" == "429" ]]; then
    count_429=$((count_429 + 1))
  else
    count_other=$((count_other + 1))
  fi
done

echo ""
echo "汇总："
echo "200: $count_200"
echo "429: $count_429"
echo "other: $count_other"
echo ""

if [[ "$count_429" -ge 1 ]]; then
  echo "PASS: 出现 429"
else
  echo "FAIL: 未出现 429，请把 QUEUE_SIZE 再调小或增大并发"
  exit 1
fi
#!/bin/bash
# Stage4 queue-full reproduction: fire concurrent txt2img requests and expect 429.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
RAW_DIR="$OUT_DIR/queue429"
STATUS_FILE="$RAW_DIR/.status.log"

mkdir -p "$RAW_DIR"

source "$BIN/_common.sh"

BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
N="${N:-8}"
QUEUE_ENV="${QUEUE_SIZE:-1}"

if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 1 ]; then
  echo "ERROR: 并发 N 必须是正整数，当前 N=$N" >&2
  exit 1
fi

echo "=== queue_429 smoke ==="
echo "BASE_URL=$BASE_URL"
echo "N=$N"
echo "EXPECT_QUEUE_SIZE=$QUEUE_ENV"
echo ""
echo "操作步骤提醒："
echo "  1. 停止当前运行的 ./start.sh"
echo "  2. 以更小队列重启，例如："
echo "     QUEUE_SIZE=$QUEUE_ENV nohup ./start.sh > logs/restart_queue${QUEUE_ENV}.log 2>&1 &"
echo "  3. 待 readyz=200 后运行本脚本："
echo "     BASE_URL=$BASE_URL bash cli_tests/bin/41_queue_429.sh | tee cli_tests/out/stage4_queue429.txt"
echo ""

echo "--- Step: healthz check ---"
if ! curl -sS --fail --max-time 5 "$BASE_URL/healthz" >/dev/null; then
  echo "ERROR: $BASE_URL/healthz 不可用，退出。" >&2
  exit 1
fi
echo "healthz OK"
echo ""

run_request() {
  local idx="$1"
  local raw_file="$RAW_DIR/raw_${idx}.txt"
  local ts
  ts="$(date -Iseconds)"
  local resp body code body_preview
  resp=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/v1/images/generations" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\":\"queue429-$idx\",\"n\":1,\"size\":\"512x512\",\"steps\":25,\"sync\":true}" 2>&1 || true)
  body=$(echo "$resp" | head -n -1)
  code=$(echo "$resp" | tail -n 1 | tr -d '[:space:]')
  if [[ ! "$code" =~ ^[0-9]{3}$ ]]; then
    body="$resp"
    code="curl_error"
  fi
  body_preview=$(echo "$body" | head -c 200)
  {
    echo "timestamp: $ts"
    echo "status: $code"
    echo "body(<=200c):"
    echo "$body_preview"
  } > "$raw_file"
  printf "%s %s %s\n" "$idx" "$code" "$ts" >> "$STATUS_FILE"
  echo "[raw_$idx] status=$code ts=$ts"
}

# Cleanup previous run artifacts
rm -f "$RAW_DIR"/raw_*.txt
rm -f "$STATUS_FILE"
touch "$STATUS_FILE"

echo "--- Step: firing $N concurrent txt2img requests ---"
for ((i = 1; i <= N; i++)); do
  run_request "$i" &
done
wait
echo "所有请求完成。"
echo ""

total=$(wc -l < "$STATUS_FILE" | tr -d ' ')
count_200=$(grep -c ' 200 ' "$STATUS_FILE" || true)
count_429=$(grep -c ' 429 ' "$STATUS_FILE" || true)
count_other=$(( total - count_200 - count_429 ))
if [ "$total" -lt "$N" ]; then
  echo "WARNING: 仅记录到 $total/$N 个响应。" >&2
fi

echo "--- Summary ---"
echo "200 responses : $count_200"
echo "429 responses : $count_429"
echo "other responses: $count_other"
echo ""

if [ "$count_429" -gt 0 ]; then
  echo "PASS: 检测到 429，证明队列容量受限。"
  exit 0
else
  echo "FAIL: 未触发 429。请尝试减小 QUEUE_SIZE 或增大并发 (N=$N)。" >&2
  exit 2
fi
