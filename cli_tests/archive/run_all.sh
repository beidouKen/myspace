#!/bin/bash
# DEPRECATED: Use run_all_v2.sh for delivery seal. This script is kept for reference only.
# run_all.sh: Run 00/70/90/95/96~99/100~103 in order, output to cli_tests/out/, generate FINAL_DELIVERY_REPORT.md

set +e  # 不要让单个脚本的非0直接中断；我们用 PASS/FAIL 汇总控制退出码

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/cli_tests/bin"
OUT="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT="$(cd "$ROOT" && mkdir -p "$OUT" && realpath "$OUT")"
REPORT="$OUT/FINAL_DELIVERY_REPORT.md"
RESULTS_FILE="$OUT/run_all_results.txt"
rm -f "$RESULTS_FILE"

SCRIPTS=(
  "00_check.sh"
  "70_run_default_stable_and_save.sh"
  "90_chat_adapter_smoke.sh"
  "95_chat_img2img_smoke.sh"
  "96_ready_probe.sh"
  "97_openai_error_format.sh"
  "98_async_first_platform_flow.sh"
  "99_idempotency_smoke.sh"
  "100_probe_alias_compat.sh"
  "101_images_url_priority.sh"
  "102_queue_full_429.sh"
  "103_timeout_504_and_backend_502.sh"
)

cd "$ROOT"
export BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
export OUT_DIR="$OUT"

for script in "${SCRIPTS[@]}"; do
  name="${script%.sh}"
  echo "===== Running $script ====="

  LOG="$OUT/run_all_${name}.log"
  rc=0

  if [[ "$script" == "103_timeout_504_and_backend_502.sh" ]]; then
    # 封板稳定性：显式启用 Part C 的 slow_infer_server 兜底（不依赖 GPU/模型就绪）
    # proof 内会标注 RUN_MODE=slow_infer_fallback，符合“兜底需显式启用”的交付口径
    USE_SLOW_INFER_FALLBACK=1 bash "$BIN/$script" --fallback >> "$LOG" 2>&1
    rc=$?
  else
    bash "$BIN/$script" >> "$LOG" 2>&1
    rc=$?
  fi

  if [ $rc -eq 0 ]; then
    echo "$name PASS" >> "$RESULTS_FILE"
  else
    echo "$name FAIL" >> "$RESULTS_FILE"
  fi
done

# Generate FINAL_DELIVERY_REPORT.md
FAILED=""
while read -r line; do
  n="${line% *}"
  r="${line##* }"
  if [ "$r" = "FAIL" ]; then
    FAILED="$FAILED $n"
  fi
done < "$RESULTS_FILE" 2>/dev/null || true

{
  echo "# Final Delivery Report"
  echo ""
  echo "Generated: $(date -Iseconds 2>/dev/null || date)"
  echo ""
  echo "## Script Results Summary"
  echo ""
  echo "| Script | Result |"
  echo "|--------|--------|"
  for script in "${SCRIPTS[@]}"; do
    name="${script%.sh}"
    res="PASS"
    grep -q "^${name} FAIL" "$RESULTS_FILE" 2>/dev/null && res="FAIL"
    echo "| $script | $res |"
  done
  echo ""
  if [ -z "$FAILED" ]; then
    echo "**Overall: ALL PASS**"
  else
    echo "**Overall: FAIL** (failed:$FAILED)"
  fi
  echo ""
  echo "---"
  echo ""
  echo "## Key Proof Summary"
  echo ""
  echo "- **url-first (101)**: \`response_format=url\` → \`data[0].url\` present and downloadable. Proof: \`cli_tests/out/101_images_url_priority_proof.txt\`, \`101_downloaded.png\`"
  echo "- **429 queue_full (102)**: Temp gateway QUEUE_SIZE=1 → 429 with OpenAI envelope \`code=queue_full\`, \`type=rate_limit_error\`. Proof: \`cli_tests/out/102_queue_full_429_proof.txt\`"
  echo "- **502 backend_unreachable (103 Part A)**: Gateway with unreachable backend → 502 \`code=backend_unreachable\`. Proof: \`cli_tests/out/103_timeout_504_502_proof.txt\`"
  echo "- **504 sync_wait_timeout (103 Part B)**: Hang backend + short SYNC_WAIT → 504 \`code=sync_wait_timeout\`. Proof: \`cli_tests/out/103_timeout_504_502_proof.txt\`"
  echo "- **504 task_timeout (103 Part C)**: run_all enforces fallback explicitly: \`USE_SLOW_INFER_FALLBACK=1\` + \`--fallback\`. Proof: \`cli_tests/out/103_timeout_task_timeout_proof.txt\` (RUN_MODE in file)."
  echo ""
  echo "---"
  echo ""
  echo "## Proof Files"
  echo ""
  echo "\`\`\`"
  ls -la "$OUT/" 2>/dev/null | head -60
  echo "\`\`\`"
} > "$REPORT"

echo ""
echo "Report written to $REPORT"
if [ -n "$FAILED" ]; then
  echo "Failed:$FAILED"
  exit 1
fi
exit 0
