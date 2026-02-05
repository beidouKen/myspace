#!/bin/bash
# Shared vars for cli_tests/bin/*.sh - source this or common.sh
export BASE_URL="${BASE_URL:-http://127.0.0.1:${PORT:-8000}}"
export CURL="curl -sS --fail"
echo "BASE_URL=$BASE_URL"
