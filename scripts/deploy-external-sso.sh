#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
CONFIRM=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deploy-external-sso.sh     --confirm REVINT_EXTERNAL_SSO

Requires a real public domain, a domain-matching TLS certificate,
and registered OIDC client credentials.
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$CONFIRM" == "REVINT_EXTERNAL_SSO" ]] || {
  usage
  fail "external SSO confirmation token is missing."
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$ROOT_DIR/deploy/tls/tls.crt" ]] || fail "TLS certificate is missing."
[[ -f "$ROOT_DIR/deploy/tls/tls.key" ]] || fail "TLS private key is missing."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

required=(
  OAUTH2_PROXY_IMAGE SSO_ENABLED SSO_IDENTITY_PROVIDER_KEY
  SSO_OIDC_ISSUER_URL SSO_OIDC_CLIENT_ID SSO_OIDC_CLIENT_SECRET
  SSO_ALLOWED_EMAIL_DOMAINS SSO_COOKIE_SECRET SSO_INTERNAL_API_KEY
  PUBLIC_DOMAIN PUBLIC_HTTPS_ORIGIN INGRESS_BIND_ADDRESS
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or uses a placeholder."
done

[[ "$SSO_ENABLED" == "true" ]] || fail "SSO_ENABLED must be true."
[[ "$OAUTH2_PROXY_IMAGE" == *@sha256:* ]] || fail "OAUTH2_PROXY_IMAGE must use an immutable sha256 digest."
[[ "$SSO_IDENTITY_PROVIDER_KEY" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || fail "SSO_IDENTITY_PROVIDER_KEY is invalid."
[[ "$SSO_OIDC_ISSUER_URL" =~ ^https://[^[:space:]]+$ ]] || fail "SSO_OIDC_ISSUER_URL must use HTTPS."
[[ "$PUBLIC_DOMAIN" != "localhost" ]] || fail "external SSO requires a real PUBLIC_DOMAIN."
[[ "$INGRESS_BIND_ADDRESS" != "127.0.0.1" && "$INGRESS_BIND_ADDRESS" != "::1" ]] ||   fail "external SSO requires a non-loopback ingress bind."

expected_origin="https://$PUBLIC_DOMAIN"
[[ "$PUBLIC_HTTPS_ORIGIN" == "$expected_origin" ]] ||   fail "PUBLIC_HTTPS_ORIGIN must be exactly $expected_origin"
[[ "${N8N_WEBHOOK_URL:-}" == "$PUBLIC_HTTPS_ORIGIN/" ]] ||   fail "N8N_WEBHOOK_URL must match the public HTTPS origin."

openssl x509 -in "$ROOT_DIR/deploy/tls/tls.crt" -noout -checkend 300 >/dev/null ||   fail "TLS certificate is expired or expires too soon."
openssl x509 -in "$ROOT_DIR/deploy/tls/tls.crt" -noout -checkhost "$PUBLIC_DOMAIN" >/dev/null ||   fail "TLS certificate does not match PUBLIC_DOMAIN."

bash "$ROOT_DIR/scripts/deploy-sso-core.sh"

docker compose --profile sso --env-file "$ENV_FILE" -f "$COMPOSE_FILE"   up -d oauth2-proxy

for attempt in $(seq 1 30); do
  if docker compose --profile ingress --profile sso       --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T ingress       wget -q -O - http://oauth2-proxy:4180/ping >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" -ne 30 ]] || fail "OAuth2 Proxy did not become reachable."
  sleep 2
done

bash "$ROOT_DIR/scripts/deploy-https-ingress.sh"   --confirm-public REVINT_PUBLIC_HTTPS_INGRESS

echo "PASS: external OIDC SSO edge deployed."
echo "CALLBACK_URL=$PUBLIC_HTTPS_ORIGIN/oauth2/callback"
echo "SSO_REPORT_URL=$PUBLIC_HTTPS_ORIGIN/sso/report"
