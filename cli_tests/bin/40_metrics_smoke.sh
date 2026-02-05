#!/bin/bash
# Stage4 metrics smoke: fetch /metrics and ensure key gauges/counters exist.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
OUT_FILE="$OUT_DIR/stage4_metrics_smoke.txt"
source "$BIN/_common.sh"

mkdir -p "$OUT_DIR"

run_ts=$(date -Iseconds)
echo "=== stage4_metrics_smoke $run_ts BASE_URL=$BASE_URL ===" | tee "$OUT_FILE"
echo "" | tee -a "$OUT_FILE"

metrics_output=$($CURL --max-time 5 "$BASE_URL/metrics")
echo "$metrics_output" | tee -a "$OUT_FILE"
echo "" | tee -a "$OUT_FILE"

required_metrics=("glm_queue_depth" "glm_inflight" "glm_backend_up" "glm_requests_total")
missing=0

for metric in "${required_metrics[@]}"; do
  if echo "$metrics_output" | grep -q "$metric"; then
    echo "(OK: found $metric)" | tee -a "$OUT_FILE"
  else
    echo "(FAIL: missing $metric)" | tee -a "$OUT_FILE"
    missing=1
  fi
done

echo "" | tee -a "$OUT_FILE"
echo "=== end stage4_metrics_smoke ===" | tee -a "$OUT_FILE"

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi
