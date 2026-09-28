#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
CONFIRM_PUBLIC=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deploy-https-ingress.sh

Public bind:
  bash scripts/deploy-https-ingress.sh     --confirm-public REVINT_PUBLIC_HTTPS_INGRESS
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm-public)
      CONFIRM_PUBLIC="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$ROOT_DIR/deploy/tls/tls.crt" ]] || fail "TLS certificate is missing."
[[ -f "$ROOT_DIR/deploy/tls/tls.key" ]] || fail "TLS private key is missing."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for name in NGINX_IMAGE PUBLIC_DOMAIN PUBLIC_HTTPS_ORIGIN INGRESS_BIND_ADDRESS INGRESS_HTTP_PORT INGRESS_HTTPS_PORT; do
  [[ -n "${!name:-}" ]] || fail "$name is missing."
done

[[ "$NGINX_IMAGE" == *@sha256:* ]] || fail "NGINX_IMAGE must use an immutable sha256 digest."
[[ "$PUBLIC_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || fail "PUBLIC_DOMAIN contains unsupported characters."
[[ "$PUBLIC_HTTPS_ORIGIN" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] ||   fail "PUBLIC_HTTPS_ORIGIN must be an https origin without a path."
[[ "$INGRESS_HTTP_PORT" =~ ^[0-9]+$ && "$INGRESS_HTTP_PORT" -ge 1 && "$INGRESS_HTTP_PORT" -le 65535 ]] ||   fail "INGRESS_HTTP_PORT must be between 1 and 65535."
[[ "$INGRESS_HTTPS_PORT" =~ ^[0-9]+$ && "$INGRESS_HTTPS_PORT" -ge 1 && "$INGRESS_HTTPS_PORT" -le 65535 ]] ||   fail "INGRESS_HTTPS_PORT must be between 1 and 65535."

if [[ "$INGRESS_BIND_ADDRESS" != "127.0.0.1" && "$INGRESS_BIND_ADDRESS" != "::1" ]]; then
  [[ "$CONFIRM_PUBLIC" == "REVINT_PUBLIC_HTTPS_INGRESS" ]] || {
    usage
    fail "public ingress confirmation token is missing."
  }

  [[ "$PUBLIC_DOMAIN" != "localhost" ]] || fail "public ingress requires a real PUBLIC_DOMAIN."
  origin_authority="${PUBLIC_HTTPS_ORIGIN#https://}"
  origin_host="${origin_authority%%:*}"
  [[ "$origin_host" == "$PUBLIC_DOMAIN" ]] ||     fail "PUBLIC_HTTPS_ORIGIN must match PUBLIC_DOMAIN exactly."

  expected_webhook="$PUBLIC_HTTPS_ORIGIN/"
  [[ "${N8N_WEBHOOK_URL:-}" == "$expected_webhook" ]] ||     fail "public ingress requires N8N_WEBHOOK_URL=$expected_webhook"
fi

openssl x509 -in "$ROOT_DIR/deploy/tls/tls.crt" -noout -checkend 60 >/dev/null ||   fail "TLS certificate is expired or invalid."
openssl pkey -in "$ROOT_DIR/deploy/tls/tls.key" -noout >/dev/null ||   fail "TLS private key is invalid."

cert_pub="$(openssl x509 -in "$ROOT_DIR/deploy/tls/tls.crt" -pubkey -noout | sha256sum | awk '{print $1}')"
key_pub="$(openssl pkey -in "$ROOT_DIR/deploy/tls/tls.key" -pubout | sha256sum | awk '{print $1}')"
[[ "$cert_pub" == "$key_pub" ]] || fail "TLS certificate and private key do not match."

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet

# Apply the trusted-proxy setting to the private backend before enabling ingress.
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --wait n8n

docker compose --profile ingress --env-file "$ENV_FILE" -f "$COMPOSE_FILE"   up -d --wait --force-recreate ingress

echo "PASS: HTTPS ingress is deployed and healthy."
echo "HTTPS_ORIGIN=$PUBLIC_HTTPS_ORIGIN"
echo "BIND_ADDRESS=$INGRESS_BIND_ADDRESS"
