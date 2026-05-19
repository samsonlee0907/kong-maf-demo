#!/usr/bin/env bash
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-kong-maf-demo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "  Kong + MAF Demo -- Cleanup"
echo "============================================"

if command -v docker >/dev/null 2>&1; then
  echo "[1/3] Stopping Kong..."
  (cd "${SCRIPT_DIR}/kong" && docker compose down) || true
else
  echo "[1/3] Docker not installed; skipping Kong shutdown."
fi

echo "[2/3] Stopping MAF server..."
pkill -f "python server.py" 2>/dev/null || true
pkill -f "uvicorn server:app" 2>/dev/null || true

echo "[3/3] Deleting Azure resource group ${RESOURCE_GROUP}..."
az group delete --name "${RESOURCE_GROUP}" --yes --no-wait

echo "Cleanup initiated."

