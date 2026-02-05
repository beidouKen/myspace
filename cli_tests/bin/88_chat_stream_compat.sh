#!/bin/bash
# 88_chat_stream_compat.sh
# Gate: stream=true 兼容 — 接受 stream=true 不报错；超时返回 202 非 504；幂等复用同一 task_id。
# 验收：带 stream:true 的长任务 → 200 或 202；若 202 轮询至 completed 含图片 url；同 payload 三次 → 同一 task_id。

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
PROOF_FILE="$OUT_DIR/proof_88.txt"
API_KEY="${API_KEY:-mysecretkey}"
SYNC_WAIT_FOR_TEST="${SYNC_WAIT_TIMEOUT_SEC:-5}"
MAX_POLL_SEC="${MAX_POLL_SEC:-300}"

mkdir -p "$OUT_DIR" "$(dirname "$LOG_DIR")"
: > "$PROOF_FILE"

echo "=== 88 Chat stream=true Compat Gate ===" | tee -a "$PROOF_FILE"
echo "BASE_URL=$BASE_URL" | tee -a "$PROOF_FILE"
echo "SYNC_WAIT_TIMEOUT_SEC (for test)=$SYNC_WAIT_FOR_TEST" | tee -a "$PROOF_FILE"

if ! curl -s --max-time 2 "$BASE_URL/health" >/dev/null 2>&1; then
    echo "Starting service with SYNC_WAIT_TIMEOUT_SEC=$SYNC_WAIT_FOR_TEST for test..."
    export SYNC_WAIT_TIMEOUT_SEC="$SYNC_WAIT_FOR_TEST"
    nohup "$ROOT/start.sh" >> "$LOG_DIR/start_88.log" 2>&1 &
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

# 会触发超时的 chat 请求（1024x1024 steps=45），显式 stream:true
CHAT_BODY='{"model":"glm-image","messages":[{"role":"user","content":"draw a dog size=1024x1024 steps=45"}],"stream":true}'

echo "" | tee -a "$PROOF_FILE"
echo "--- Request 1: POST /v1/chat/completions (stream:true, long-running) ---" | tee -a "$PROOF_FILE"

# 获取状态码、响应体、响应头（至少 Content-Type）
HTTP_CODE=$(curl -s -o "$OUT_DIR/chat_88_r1.json" -w "%{http_code}" -D "$OUT_DIR/chat_88_r1_headers.txt" \
    -X POST "$BASE_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$CHAT_BODY")

CONTENT_TYPE=$(grep -i "^Content-Type:" "$OUT_DIR/chat_88_r1_headers.txt" 2>/dev/null | head -1 | tr -d '\r')
echo "HTTP status: $HTTP_CODE" | tee -a "$PROOF_FILE"
echo "Response headers (excerpt): $CONTENT_TYPE" | tee -a "$PROOF_FILE"
cat "$OUT_DIR/chat_88_r1.json" | tee -a "$PROOF_FILE"
echo "" | tee -a "$PROOF_FILE"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "202" ]; then
    echo "FAIL: Expected 200 or 202, got $HTTP_CODE (no 4xx/5xx/504 allowed)" | tee -a "$PROOF_FILE"
    exit 1
fi
echo "PASS: Status 200 or 202 (no 504)." | tee -a "$PROOF_FILE"

# 从响应提取 task_id：202 为 body.task_id，200 为 body.id 去掉 chatcmpl- 前缀
TASK_ID_1=""
if [ "$HTTP_CODE" = "202" ]; then
    TASK_ID_1=$(python3 -c "import json; d=json.load(open('$OUT_DIR/chat_88_r1.json')); print(d.get('task_id',''))" 2>/dev/null || true)
    POLL_URL=$(python3 -c "import json; d=json.load(open('$OUT_DIR/chat_88_r1.json')); print(d.get('poll_url',''))" 2>/dev/null || true)
    echo "task_id=$TASK_ID_1" | tee -a "$PROOF_FILE"
    echo "poll_url=$POLL_URL" | tee -a "$PROOF_FILE"

    echo "" | tee -a "$PROOF_FILE"
    echo "--- Polling GET $BASE_URL/v1/tasks/$TASK_ID_1 until completed ---" | tee -a "$PROOF_FILE"
    POLL_START=$(date +%s)
    while true; do
        NOW=$(date +%s)
        if [ $((NOW - POLL_START)) -gt "$MAX_POLL_SEC" ]; then
            echo "FAIL: Poll timeout after ${MAX_POLL_SEC}s" | tee -a "$PROOF_FILE"
            exit 1
        fi
        TASK_JSON=$(curl -s "$BASE_URL/v1/tasks/$TASK_ID_1" -H "Authorization: Bearer $API_KEY")
        STATUS=$(echo "$TASK_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
        echo "  status=$STATUS" | tee -a "$PROOF_FILE"
        if [ "$STATUS" = "completed" ]; then
            echo "$TASK_JSON" > "$OUT_DIR/task_88_completed.json"
            echo "" | tee -a "$PROOF_FILE"
            echo "--- Final completed task (status, output_urls; full body in task_88_completed.json) ---" | tee -a "$PROOF_FILE"
            echo "$TASK_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Proof 只保留 status/url 等，不写入大 base64
out = {k: d.get(k) for k in ('id','status','created_at','start_time','completion_time','error','output_urls','n_outputs') if d.get(k) is not None}
out['result'] = '(omitted for proof size)' if d.get('result') else None
print(json.dumps(out, indent=2))
" | tee -a "$PROOF_FILE"
            break
        fi
        if [ "$STATUS" = "failed" ] || [ "$STATUS" = "expired" ] || [ "$STATUS" = "cancelled" ]; then
            echo "FAIL: Task ended with status=$STATUS" | tee -a "$PROOF_FILE"
            echo "$TASK_JSON" | tee -a "$PROOF_FILE"
            exit 1
        fi
        sleep 3
    done

    HAS_URL=$(echo "$TASK_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('output_urls') or d.get('result'):
    print('yes')
else:
    print('no')
" 2>/dev/null || echo "no")
    if [ "$HAS_URL" != "yes" ]; then
        echo "FAIL: Completed task has no output_urls or result" | tee -a "$PROOF_FILE"
        exit 1
    fi
    echo "PASS: Completed task has image url (output_urls/result)." | tee -a "$PROOF_FILE"
else
    # 200: id 为 chatcmpl-<task_id>
    TASK_ID_1=$(python3 -c "
import json
d = json.load(open('$OUT_DIR/chat_88_r1.json'))
cid = d.get('id') or ''
print(cid.replace('chatcmpl-','') if cid.startswith('chatcmpl-') else cid)
" 2>/dev/null || true)
fi

# 幂等：同一 payload 再发 2 次（stream:true），断言 task_id 一致
echo "" | tee -a "$PROOF_FILE"
echo "--- Request 2 & 3: same payload (stream:true) — idempotency same task_id ---" | tee -a "$PROOF_FILE"

for r in 2 3; do
    HTTP_CODE_R=$(curl -s -o "$OUT_DIR/chat_88_r${r}.json" -w "%{http_code}" \
        -X POST "$BASE_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$CHAT_BODY")
    echo "Request $r HTTP status: $HTTP_CODE_R" | tee -a "$PROOF_FILE"
    if [ "$HTTP_CODE_R" != "200" ] && [ "$HTTP_CODE_R" != "202" ]; then
        echo "FAIL: Request $r got $HTTP_CODE_R" | tee -a "$PROOF_FILE"
        exit 1
    fi
    TASK_ID_R=""
    if [ "$HTTP_CODE_R" = "202" ]; then
        TASK_ID_R=$(python3 -c "import json; d=json.load(open('$OUT_DIR/chat_88_r${r}.json')); print(d.get('task_id',''))" 2>/dev/null || true)
    else
        TASK_ID_R=$(python3 -c "
import json
d = json.load(open('$OUT_DIR/chat_88_r${r}.json'))
cid = d.get('id') or ''
print(cid.replace('chatcmpl-','') if cid.startswith('chatcmpl-') else cid)
" 2>/dev/null || true)
    fi
    echo "Request $r task_id: $TASK_ID_R" | tee -a "$PROOF_FILE"
    if [ -z "$TASK_ID_R" ]; then
        echo "FAIL: Request $r missing task_id/id" | tee -a "$PROOF_FILE"
        exit 1
    fi
    if [ "$TASK_ID_R" != "$TASK_ID_1" ]; then
        echo "FAIL: Idempotency broken — request $r task_id=$TASK_ID_R != first=$TASK_ID_1" | tee -a "$PROOF_FILE"
        exit 1
    fi
done
echo "PASS: All three responses share same task_id ($TASK_ID_1)." | tee -a "$PROOF_FILE"

echo "" | tee -a "$PROOF_FILE"
echo "=== Gate 88 PASS ===" | tee -a "$PROOF_FILE"
echo "Proof written to: $PROOF_FILE"
