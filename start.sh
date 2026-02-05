#!/bin/bash
# Thin wrapper: run the real start script from scripts/ (must run from repo root for app/ and logs/)
cd "$(dirname "$0")" && exec bash scripts/start.sh "$@"
