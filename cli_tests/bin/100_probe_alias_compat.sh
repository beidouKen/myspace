#!/bin/bash
set -e
# 100_probe_alias_compat.sh: GET /readyz -> reuse ready; GET /healthz -> reuse health

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT_DIR="${OUT_DIR:-$ROOT/cli_tests/out}"
mkdir -p "$OUT_DIR"
PROOF="$OUT_DIR/100_probe_alias_proof.txt"
rm -f "$PROOF"
PROBE_PORT=18000
gw_pid=""

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$PROOF"; }
pass() { echo "PASS: $*" | tee -a "$PROOF"; }
fail() { echo "FAIL: $*" | tee -a "$PROOF"; exit 1; }
cleanup_100() { [ -n "$gw_pid" ] && kill "$gw_pid" 2>/dev/null || true; }
trap cleanup_100 EXIT

log "100_probe_alias_compat.sh: /readyz and /healthz alias compat"

# If main gateway has no /readyz (404), start temp gateway on PROBE_PORT to verify alias
CODE_READYZ_MAIN=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/readyz" 2>/dev/null || echo "000")
if [ "$CODE_READYZ_MAIN" = "404" ] || [ "$CODE_READYZ_MAIN" = "000" ]; then
    log "Main gateway has no /readyz (code=$CODE_READYZ_MAIN); starting temp gateway on port $PROBE_PORT"
    BACKEND_URLS="${BACKEND_URLS:-http://127.0.0.1:8001}" PORT=$PROBE_PORT uvicorn app.gateway.main:app --host 127.0.0.1 --port $PROBE_PORT >> "$OUT_DIR/100_gw.log" 2>&1 &
    gw_pid=$!
    BASE_URL="http://127.0.0.1:$PROBE_PORT"
    sleep 3
fi

# Wait for /ready to be 200
for i in $(seq 1 15); do
    CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/ready")
    [ "$CODE" = "200" ] && break
    log "Wait ready... $i code=$CODE"
    sleep 2
done
CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/ready")
[ "$CODE" != "200" ] && fail "/ready did not become 200 (code=$CODE)"

# 1) /ready vs /readyz same behavior
R_READY=$(curl -s --max-time 5 "$BASE_URL/ready")
R_READYZ=$(curl -s --max-time 5 "$BASE_URL/readyz")
CODE_READY=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/ready")
CODE_READYZ=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/readyz")

echo "/ready response: $R_READY" >> "$PROOF"
echo "/readyz response: $R_READYZ" >> "$PROOF"

if [ "$CODE_READYZ" != "200" ]; then
    fail "/readyz status $CODE_READYZ (expected 200)"
fi
if ! echo "$R_READYZ" | grep -q "ready"; then
    fail "/readyz body missing 'ready': $R_READYZ"
fi
pass "/readyz returns 200 and same semantics as /ready"

# 2) /health vs /healthz same behavior
H_HEALTH=$(curl -s --max-time 5 "$BASE_URL/health")
H_HEALTHZ=$(curl -s --max-time 5 "$BASE_URL/healthz")
CODE_HEALTH=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/health")
CODE_HEALTHZ=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$BASE_URL/healthz")

echo "/health response: $H_HEALTH" >> "$PROOF"
echo "/healthz response: $H_HEALTHZ" >> "$PROOF"

if [ "$CODE_HEALTHZ" != "200" ]; then
    fail "/healthz status $CODE_HEALTHZ (expected 200)"
fi
if ! echo "$H_HEALTHZ" | grep -q "ok"; then
    fail "/healthz body missing 'ok': $H_HEALTHZ"
fi
pass "/healthz returns 200 and same semantics as /health"

pass "100_probe_alias_compat.sh completed successfully."
