#!/bin/bash
# run_all_v2.sh: Stage4 封板执行器
# 按序跑 00/70/90/95/96~99/100~103；不杀主服务；每脚本 timeout；主服务掉线即 FAIL 并报告凶手脚本；静态扫描危险宽杀；生成真实 FINAL_DELIVERY_REPORT.md

set +e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/cli_tests/bin"
OUT="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT="$(cd "$ROOT" && mkdir -p "$OUT" && realpath "$OUT")"
REPORT="$OUT/FINAL_DELIVERY_REPORT.md"
RESULTS_FILE="$OUT/run_all_v2_results.txt"
FAIL_REASONS_FILE="$OUT/run_all_v2_fail_reasons.txt"
DEFAULT_TIMEOUT=600
TIMEOUT_103=180
rm -f "$RESULTS_FILE" "$FAIL_REASONS_FILE"

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

# 检查端口是否在监听（主服务 8000/8001）
check_port_listening() {
  local port=$1
  if command -v ss &>/dev/null; then
    ss -ltn 2>/dev/null | grep -q ":${port} "
    return $?
  fi
  if command -v netstat &>/dev/null; then
    netstat -ltn 2>/dev/null | grep -q ":${port} "
    return $?
  fi
  return 1
}

# 跑前记录主服务端口 8000/8001 的监听 pid（用于报告；校验时只要求仍在监听）
record_main_pids() {
  MAIN_PID_8000=""
  MAIN_PID_8001=""
  if command -v ss &>/dev/null; then
    MAIN_PID_8000=$(ss -ltnp 2>/dev/null | awk '$4~/:8000$/ {gsub(/.*pid=/,""); sub(/,.*/,""); print; exit}')
    MAIN_PID_8001=$(ss -ltnp 2>/dev/null | awk '$4~/:8001$/ {gsub(/.*pid=/,""); sub(/,.*/,""); print; exit}')
  fi
  export MAIN_PID_8000 MAIN_PID_8001
}

# 校验 8000/8001 仍在监听；若掉线返回非 0
verify_main_service_up() {
  check_port_listening 8000 && check_port_listening 8001
}

# 静态扫描：若脚本包含危险宽杀（pkill/killall/pgrep+kill 等），返回非 0
scan_dangerous_kill() {
  local script_path=$1
  if grep -E 'pkill|killall' "$script_path" 2>/dev/null; then
    return 1
  fi
  if grep -q 'pgrep' "$script_path" 2>/dev/null && grep -q 'kill' "$script_path" 2>/dev/null; then
    # 简单启发：同一脚本内同时出现 pgrep 与 kill 可能构成宽杀
    if grep -E 'kill.*\$\(.*pgrep|pgrep.*\).*kill' "$script_path" 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

cd "$ROOT"
export BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"
export OUT_DIR="$OUT"

# ---------- 静态扫描：危险宽杀 ----------
echo "[run_all_v2] Static scan for dangerous broad kill (pkill/killall/pgrep+kill)..."
SCAN_FAIL=0
for script in "${SCRIPTS[@]}"; do
  if ! scan_dangerous_kill "$BIN/$script"; then
    echo "FAIL: Script contains dangerous broad kill (pkill/killall/pgrep+kill): $script"
    echo "Fix: Remove pkill/killall; use only PID-precise kill of recorded PIDs (e.g. gw_pid, slow_pid)."
    SCAN_FAIL=1
    break
  fi
done
[ $SCAN_FAIL -eq 1 ] && exit 1
echo "[run_all_v2] Static scan passed."

# ---------- 跑前记录主服务 ----------
record_main_pids
if ! verify_main_service_up; then
  echo "FAIL: Main service not up (8000/8001 not listening). Start with ./start.sh and ensure /readyz=200 first."
  exit 1
fi
echo "[run_all_v2] Main service 8000/8001 listening. PIDs: 8000=${MAIN_PID_8000:-?} 8001=${MAIN_PID_8001:-?}"

# ---------- 按序执行 ----------
KILLER_SCRIPT=""
for script in "${SCRIPTS[@]}"; do
  name="${script%.sh}"
  LOG="$OUT/run_all_v2_${name}.log"
  echo "===== Running $script (log: run_all_v2_${name}.log) ====="

  if [[ "$script" == "103_timeout_504_and_backend_502.sh" ]]; then
    timeout $TIMEOUT_103 env USE_SLOW_INFER_FALLBACK=1 bash "$BIN/$script" --fallback >> "$LOG" 2>&1
  else
    timeout $DEFAULT_TIMEOUT bash "$BIN/$script" >> "$LOG" 2>&1
  fi
  rc=$?

  if ! verify_main_service_up; then
    echo "$name FAIL (main service down after this script; 凶手脚本: $script)" >> "$RESULTS_FILE"
    echo "主服务掉线，凶手脚本: $script" >> "$FAIL_REASONS_FILE"
    KILLER_SCRIPT="$script"
    break
  fi

  if [ $rc -eq 0 ]; then
    echo "$name PASS" >> "$RESULTS_FILE"
  else
    echo "$name FAIL" >> "$RESULTS_FILE"
    echo "Script exit code: $rc" >> "$FAIL_REASONS_FILE"
    tail -20 "$LOG" >> "$FAIL_REASONS_FILE" 2>/dev/null || true
  fi
done

# ---------- 生成 FINAL_DELIVERY_REPORT.md ----------
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
  echo "## Env Snapshot"
  echo ""
  echo "\`\`\`"
  echo "BASE_URL=${BASE_URL:-http://127.0.0.1:8000}"
  echo "OUT_DIR=$OUT"
  echo "MAIN_PID_8000=${MAIN_PID_8000:-?} MAIN_PID_8001=${MAIN_PID_8001:-?}"
  [ -n "$KILLER_SCRIPT" ] && echo "KILLER_SCRIPT=$KILLER_SCRIPT (main service down after this script)"
  echo "\`\`\`"
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
  if [ -z "$FAILED" ] && [ -z "$KILLER_SCRIPT" ]; then
    echo "**Overall: ALL PASS**"
  else
    echo "**Overall: FAIL** (failed:$FAILED)"
    [ -n "$KILLER_SCRIPT" ] && echo ""
    echo "主服务掉线时凶手脚本: $KILLER_SCRIPT"
  fi
  echo ""
  echo "## Failure Reason (if any)"
  echo ""
  if [ -f "$FAIL_REASONS_FILE" ] && [ -s "$FAIL_REASONS_FILE" ]; then
    echo "\`\`\`"
    cat "$FAIL_REASONS_FILE"
    echo "\`\`\`"
  else
    echo "(none)"
  fi
  echo ""
  echo "---"
  echo ""
  echo "## Key Proof Summary"
  echo ""
  echo "- **url-first (101)**: \`cli_tests/out/101_images_url_priority_proof.txt\`, \`101_downloaded.png\`"
  echo "- **429 queue_full (102)**: \`cli_tests/out/102_queue_full_429_proof.txt\`"
  echo "- **502/504 (103)**: \`cli_tests/out/103_timeout_504_502_proof.txt\`, \`cli_tests/out/103_timeout_task_timeout_proof.txt\` (RUN_MODE=slow_infer_fallback)"
  echo ""
  echo "---"
  echo ""
  echo "## Proof Files"
  echo ""
  echo "\`\`\`"
  ls -la "$OUT/" 2>/dev/null | head -80
  echo "\`\`\`"
} > "$REPORT"

echo ""
echo "Report written to $REPORT"
if [ -n "$FAILED" ] || [ -n "$KILLER_SCRIPT" ]; then
  [ -n "$KILLER_SCRIPT" ] && echo "主服务掉线，凶手脚本: $KILLER_SCRIPT"
  echo "Failed:$FAILED"
  exit 1
fi
exit 0
