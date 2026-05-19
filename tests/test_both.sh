#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KONG_URL="${KONG_URL:-http://localhost:8000}"
AGENT_URL="${AGENT_URL:-http://localhost:8080}"

echo "============================================"
echo "  Kong + MAF Demo -- Full Test Suite"
echo "============================================"
echo ""

echo "[Pre-check] Verifying services..."
curl -sf "${KONG_URL}/health" >/dev/null && echo "  Kong is reachable" || {
  echo "  Kong not reachable at ${KONG_URL}"
  exit 1
}
curl -sf "${AGENT_URL}/health" >/dev/null && echo "  MAF server is reachable" || {
  echo "  MAF server not reachable at ${AGENT_URL}"
  exit 1
}
echo ""

python "${SCRIPT_DIR}/test_non_sse.py"
echo ""
python "${SCRIPT_DIR}/test_sse.py"
