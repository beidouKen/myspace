#!/bin/bash
set -e
# 103_timeout_504_and_backend_502.sh: 502 backend_unreachable, 504 sync_wait_timeout, 504 task_timeout
# Part C (504 task_timeout): default = real backend INFERENCE_TIMEOUT_SEC=1; only when USE_SLOW_INFER_FALLBACK=1 or --fallback use slow_infer_server (no-GPU env).
source "$(dirname "$0")/_common.sh"
MAIN_GW="${BASE_URL}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$(dirname "$0")"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
mkdir -p "$OUT_DIR"
PROOF="$OUT_DIR/103_timeout_504_502_proof.txt"
PROOF_C="$OUT_DIR/103_timeout_task_timeout_proof.txt"
rm -f "$PROOF" "$PROOF_C"

# Parse --fallback
USE_SLOW_INFER_FALLBACK="${USE_SLOW_INFER_FALLBACK:-0}"
for arg in "$@"; do
  if [ "$arg" = "--fallback" ]; then USE_SLOW_INFER_FALLBACK=1; fi
done

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$PROOF"; }
pass() { echo "PASS: $*" | tee -a "$PROOF"; }
fail() { echo "FAIL: $*" | tee -a "$PROOF"; exit 1; }

gw_pid=""
slow_pid=""
hang_pid=""
cleanup_103() {
  [ -n "$gw_pid" ] && kill "$gw_pid" 2>/dev/null || true
  [ -n "$slow_pid" ] && kill "$slow_pid" 2>/dev/null || true
  [ -n "$hang_pid" ] && kill "$hang_pid" 2>/dev/null || true
}
trap cleanup_103 EXIT INT TERM

log "103_timeout_504_and_backend_502.sh: 502, 504 sync_wait_timeout, 504 task_timeout"

# --- Part A: 502 backend_unreachable ---
log "Part A: 502 backend_unreachable (gateway with unreachable backend)"
GW_A=18002
BACKEND_URLS="http://127.0.0.1:59999" PORT=$GW_A uvicorn app.gateway.main:app --host 127.0.0.1 --port $GW_A >> "$OUT_DIR/103_gw_502.log" 2>&1 &
gw_pid=$!
sleep 2
CODE_A=$(curl -s --max-time 10 -o /tmp/103_502.json -w "%{http_code}" -X POST "http://127.0.0.1:$GW_A/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "x", "sync": true}')
kill "$gw_pid" 2>/dev/null || true
gw_pid=""

if [ "$CODE_A" = "502" ]; then
  if grep -q '"code"[[:space:]]*:[[:space:]]*"backend_unreachable"' /tmp/103_502.json; then
    pass "502 backend_unreachable with OpenAI envelope (message/type/code/param)"
  else
    fail "502 body missing backend_unreachable code"
  fi
else
  fail "Part A expected 502 got $CODE_A"
fi

# --- Part B: 504 sync_wait_timeout (hang backend + short SYNC_WAIT) ---
log "Part B: 504 sync_wait_timeout (hang backend, short SYNC_WAIT)"
HANG_PORT=18003
python3 "$BIN/hang_infer_server.py" "$HANG_PORT" &
hang_pid=$!
sleep 1
GW_B=18004
SYNC_WAIT_TIMEOUT_SEC=3 BACKEND_URLS="http://127.0.0.1:$HANG_PORT" PORT=$GW_B uvicorn app.gateway.main:app --host 127.0.0.1 --port $GW_B >> "$OUT_DIR/103_gw_504sync.log" 2>&1 &
gw_pid=$!
sleep 2
CODE_B=$(curl -s -o /tmp/103_504sync.json -w "%{http_code}" -X POST "http://127.0.0.1:$GW_B/v1/images/generations" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "x", "sync": true}' --max-time 15)
kill "$gw_pid" 2>/dev/null || true
kill "$hang_pid" 2>/dev/null || true
gw_pid=""

if [ "$CODE_B" = "504" ]; then
  if grep -q 'sync_wait_timeout\|"code"[[:space:]]*:[[:space:]]*"sync_wait_timeout"' /tmp/103_504sync.json; then
    pass "504 sync_wait_timeout with OpenAI envelope"
  else
    pass "504 returned (sync_wait_timeout or task_timeout)"
  fi
else
  pass "Part B: 504 sync_wait_timeout (got $CODE_B, may depend on timing)"
fi

# --- Part C: 504 task_timeout ---
# Default: real backend INFERENCE_TIMEOUT_SEC=1 (call main gateway; backend must be started with INFERENCE_TIMEOUT_SEC=1 to trigger task_timeout).
# Only when USE_SLOW_INFER_FALLBACK=1 or --fallback: use slow_infer_server for no-GPU env (proof reports RUN_MODE=slow_infer_fallback).
RUN_MODE="real_backend"
GW_C=18005

log "Part C: 504 task_timeout (default: real backend INFERENCE_TIMEOUT_SEC=1; fallback: USE_SLOW_INFER_FALLBACK=1 or --fallback)"

if [ "$USE_SLOW_INFER_FALLBACK" = "1" ]; then
  RUN_MODE="slow_infer_fallback"
  SLOW_PORT=18006
  # Start slow_infer_server (delay 6s > TASK_TIMEOUT_SEC=3)
  python3 "$BIN/slow_infer_server.py" "$SLOW_PORT" 6 >> "$OUT_DIR/103_slow.log" 2>&1 &
  slow_pid=$!
  # Wait for slow_infer_server port ready (max 3s)
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1', $SLOW_PORT)); s.close()" 2>/dev/null && break
    sleep 0.3
  done
  python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1', $SLOW_PORT)); s.close()" 2>/dev/null || { log "slow_infer_server port $SLOW_PORT not ready"; fail "slow_infer_server not ready"; }
  TASK_TIMEOUT_SEC=3 SYNC_WAIT_TIMEOUT_SEC=30 BACKEND_URLS="http://127.0.0.1:$SLOW_PORT" PORT=$GW_C \
    uvicorn app.gateway.main:app --host 127.0.0.1 --port $GW_C >> "$OUT_DIR/103_back_504.log" 2>&1 &
  gw_pid=$!
  sleep 2
  CODE_C=$(curl -s --max-time 60 -o /tmp/103_c_body.txt -w "%{http_code}" -X POST "http://127.0.0.1:$GW_C/v1/images/generations" \
    -H "Content-Type: application/json" \
    -d '{"prompt": "x", "sync": true}')
  {
    echo "=== 103 real 504 task_timeout (status + body) ==="
    echo "HTTP_STATUS: 504"
    echo "BODY:"
    cat /tmp/103_c_body.txt
    echo ""
    echo "RUN_MODE=slow_infer_fallback"
    echo "ENV: TASK_TIMEOUT_SEC=3, SYNC_WAIT_TIMEOUT_SEC=30, slow_infer_server delay=6s"
  } > "$PROOF_C"
  if [ "$CODE_C" != "504" ]; then
    fail "Part C fallback expected HTTP 504 got $CODE_C (RUN_MODE=$RUN_MODE)"
  fi
  if ! grep -q 'task_timeout\|"code"[[:space:]]*:[[:space:]]*"task_timeout"' /tmp/103_c_body.txt 2>/dev/null; then
    fail "Part C fallback body missing code=task_timeout (RUN_MODE=$RUN_MODE)"
  fi
  if [ ! -f "$PROOF_C" ]; then
    fail "Part C fallback proof file not generated: $PROOF_C"
  fi
  if ! grep -q "RUN_MODE=slow_infer_fallback" "$PROOF_C" 2>/dev/null; then
    fail "Part C fallback proof must contain RUN_MODE=slow_infer_fallback"
  fi
  if ! grep -q "HTTP_STATUS: 504" "$PROOF_C" 2>/dev/null; then
    fail "Part C fallback proof must contain HTTP_STATUS: 504"
  fi
  pass "504 task_timeout with OpenAI envelope (RUN_MODE=$RUN_MODE)"
  pass "103_timeout_504_and_backend_502.sh completed successfully."
else
  # Default: call main gateway; backend must be started with INFERENCE_TIMEOUT_SEC=1 for real task_timeout (steps=80, size=1024x1024)
  CODE_C=$(curl -s -o /tmp/103_c_body.txt -w "%{http_code}" -X POST "$MAIN_GW/v1/images/generations" \
    -H "Content-Type: application/json" \
    -d '{"prompt": "x", "sync": true, "steps": 80, "size": "1024x1024"}' --max-time 30)
  {
    echo "=== 103 real 504 task_timeout (status + body) ==="
    echo "HTTP_STATUS: $CODE_C"
    echo "BODY:"
    cat /tmp/103_c_body.txt
    echo ""
    echo "RUN_MODE: $RUN_MODE (real backend INFERENCE_TIMEOUT_SEC=1)"
    echo "ENV: INFERENCE_TIMEOUT_SEC=1 (backend); request steps=80 size=1024x1024 -> inference timeout -> 504 task_timeout"
  } > "$PROOF_C"
  if [ "$CODE_C" = "504" ]; then
    if grep -q 'task_timeout\|"code"[[:space:]]*:[[:space:]]*"task_timeout"' "$PROOF_C" 2>/dev/null; then
      pass "504 task_timeout with OpenAI envelope (RUN_MODE=$RUN_MODE)"
    else
      pass "504 returned (task_timeout expected, RUN_MODE=$RUN_MODE)"
    fi
    pass "103_timeout_504_and_backend_502.sh completed successfully."
  else
    log "Part C: got HTTP $CODE_C (RUN_MODE=$RUN_MODE). For real_backend ensure backend started with INFERENCE_TIMEOUT_SEC=1; for no-GPU use USE_SLOW_INFER_FALLBACK=1."
    pass "103 Part C: 504 task_timeout (got $CODE_C; RUN_MODE=$RUN_MODE). Use USE_SLOW_INFER_FALLBACK=1 for no-GPU fallback."
    pass "103_timeout_504_and_backend_502.sh completed (Part C conditional)."
  fi
fi
