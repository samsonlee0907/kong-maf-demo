#!/usr/bin/env bash
set -euo pipefail

agent_port="${1:-8080}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_path="${script_dir}/kong.template.yaml"
output_path="${script_dir}/kong.yaml"

if [[ ! -f "${template_path}" ]]; then
  echo "Missing local Kong template at ${template_path}" >&2
  exit 1
fi

if ! [[ "${agent_port}" =~ ^[0-9]+$ ]] || (( agent_port < 1 || agent_port > 65535 )); then
  echo "Agent port must be between 1 and 65535." >&2
  exit 1
fi

sed "s/__AGENT_UPSTREAM_PORT__/${agent_port}/g" "${template_path}" > "${output_path}"

echo "Rendered kong.yaml with FastAPI upstream port ${agent_port}"
echo "Output: ${output_path}"
