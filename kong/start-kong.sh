#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  FOUNDRY_PROJECT_ENDPOINT
  FOUNDRY_HOSTED_AGENT_NAME
)

for name in "${required_vars[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
done

export FOUNDRY_AGENT_API_VERSION="${FOUNDRY_AGENT_API_VERSION:-v1}"
refresh_seconds="${TOKEN_REFRESH_SECONDS:-2400}"
rendered_config="${KONG_DECLARATIVE_CONFIG:-/tmp/kong.azure.yaml}"
template_file="/config/kong.azure.template.yaml"
kong_prefix="${KONG_PREFIX:-/usr/local/kong}"
kong_runtime_conf="${KONG_RUNTIME_CONF:-${kong_prefix}/kong.conf}"

refresh_token() {
  if [[ -z "${IDENTITY_ENDPOINT:-}" || -z "${IDENTITY_HEADER:-}" ]]; then
    echo "Managed identity endpoint variables are not present." >&2
    exit 1
  fi

  export FOUNDRY_AGENT_BEARER_TOKEN="$(
    curl -fsS \
      -H "X-IDENTITY-HEADER: ${IDENTITY_HEADER}" \
      "${IDENTITY_ENDPOINT}?resource=https://ai.azure.com&api-version=2019-08-01" \
      | jq -r '.access_token'
  )"

  if [[ -z "${FOUNDRY_AGENT_BEARER_TOKEN}" || "${FOUNDRY_AGENT_BEARER_TOKEN}" == "null" ]]; then
    echo "Managed identity token acquisition failed." >&2
    exit 1
  fi

  envsubst < "${template_file}" > "${rendered_config}"
}

refresh_token

(
  while true; do
    sleep "${refresh_seconds}"
    refresh_token
    kong reload -p "${kong_prefix}" -c "${kong_runtime_conf}" || true
  done
) &

exec /docker-entrypoint.sh kong docker-start
