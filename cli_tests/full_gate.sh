#!/bin/bash
# full_gate.sh: 最终总验（Phase 5/最终执行）
# 执行: run_all_v2.sh + run_all_v3.sh
# Phase 1 仅创建脚本框架，不执行。

set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/bin"
OUT="${OUT_DIR:-$ROOT/out}"
OUT="$(cd "$ROOT" && mkdir -p "$OUT" && realpath "$OUT")"

echo "[full_gate] Running full gate: run_all_v2.sh + run_all_v3.sh"

export OUT_DIR="$OUT"
export BASE_URL="${BASE_URL:-http://127.0.0.1:8000}"

FAIL=0
if [ -f "$ROOT/run_all_v2.sh" ]; then
  bash "$ROOT/run_all_v2.sh" || FAIL=1
else
  echo "WARN: run_all_v2.sh not found"
  FAIL=1
fi

if [ -f "$ROOT/run_all_v3.sh" ]; then
  bash "$ROOT/run_all_v3.sh" || FAIL=1
else
  echo "WARN: run_all_v3.sh not found (placeholder; add when ready)"
fi

[ $FAIL -eq 0 ] || exit 1
exit 0
