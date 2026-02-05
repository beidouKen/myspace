#!/bin/bash
# 95_gateway_rollout_verify.sh
# Gate: 运行中 Gateway 版本/特性自证 — 通过 /healthz 断言 features 含 prefer_async，记录 build_id 与 effective_config。
# 若不包含则 FAIL，提示重启；供 Gate 94 等依赖“新网关已生效”的验收前置使用。

set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
PROOF_FILE="$OUT_DIR/proof_95.txt"

mkdir -p "$OUT_DIR"
: > "$PROOF_FILE"

echo "=== 95 Gateway Rollout Verify Gate ===" | tee -a "$PROOF_FILE"
echo "BASE_URL=$BASE_URL" | tee -a "$PROOF_FILE"

HEALTH_JSON=$(curl -s -S --max-time 5 "$BASE_URL/healthz" 2>/dev/null) || true
if [ -z "$HEALTH_JSON" ]; then
    echo "FAIL: Cannot reach $BASE_URL/healthz" | tee -a "$PROOF_FILE"
    exit 1
fi

echo "$HEALTH_JSON" > "$OUT_DIR/healthz_95.json"
echo "" | tee -a "$PROOF_FILE"
echo "--- /healthz response (excerpt) ---" | tee -a "$PROOF_FILE"

HAS_PREFER_ASYNC=$(echo "$HEALTH_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    features = d.get('features') or []
    if isinstance(features, list) and 'prefer_async' in features:
        print('yes')
    else:
        print('no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")

if [ "$HAS_PREFER_ASYNC" != "yes" ]; then
    echo "FAIL: features 中不包含 prefer_async，当前运行的仍是旧 Gateway。" | tee -a "$PROOF_FILE"
    echo "请重启/重新启动 start.sh 后再运行 Gate 94/95。" | tee -a "$PROOF_FILE"
    echo "Raw /healthz keys: $(echo "$HEALTH_JSON" | python3 -c "import sys,json; print(list(json.load(sys.stdin).keys()))" 2>/dev/null || echo 'parse failed')" | tee -a "$PROOF_FILE"
    exit 1
fi

BUILD_ID=$(echo "$HEALTH_JSON" | python3 -c "import sys, json; print(json.load(sys.stdin).get('build_id',''))" 2>/dev/null || echo "")
EFFECTIVE_CONFIG=$(echo "$HEALTH_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ec = d.get('effective_config') or {}
print(json.dumps(ec, indent=2))
" 2>/dev/null || echo "{}")

echo "build_id=$BUILD_ID" | tee -a "$PROOF_FILE"
echo "effective_config:" | tee -a "$PROOF_FILE"
echo "$EFFECTIVE_CONFIG" | tee -a "$PROOF_FILE"
echo "" | tee -a "$PROOF_FILE"
echo "PASS: Gateway 已包含 prefer_async 能力（build_id=$BUILD_ID）。" | tee -a "$PROOF_FILE"
echo "=== Gate 95 PASS ===" | tee -a "$PROOF_FILE"
echo "Proof written to: $PROOF_FILE"
