#!/bin/bash
set -euo pipefail

# Load base URL and CURL (and print BASE_URL)
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/_common.sh"

# Configuration
export API_KEY=${API_KEY:-""}
export LOG_DIR="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/logs"
export OUT_DIR="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/out"

mkdir -p "$LOG_DIR" "$OUT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    exit 1
}

get_json_value() {
    local json="$1"
    local key="$2"
    echo "$json" | python3 -c "import sys, json; print(json.load(sys.stdin)$key)" 2>/dev/null || echo ""
}

# Construct curl args function
curl_cmd() {
    local args=("-s")
    if [ -n "$API_KEY" ]; then
        args+=("-H" "Authorization: Bearer $API_KEY")
    fi
    echo "curl ${args[@]}"
}

# Helper variable for curl with auth
CURL_AUTH="$(curl_cmd)"

