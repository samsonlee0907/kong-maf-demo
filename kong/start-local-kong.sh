#!/usr/bin/env bash
set -euo pipefail

agent_port="${1:-8080}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${script_dir}/render-local-config.sh" "${agent_port}"

(
  cd "${script_dir}"
  docker compose up -d
)

echo
echo "Local Kong started on http://127.0.0.1:8000"
echo "Upstream FastAPI port: ${agent_port}"
