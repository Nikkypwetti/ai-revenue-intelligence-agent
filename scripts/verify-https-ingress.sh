#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
CERT="$ROOT_DIR/deploy/tls/tls.crt"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -f "$CERT" ]] || fail "TLS certificate is missing."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

[[ "$NGINX_IMAGE" == *@sha256:* ]] || fail "NGINX_IMAGE is not immutable."

resolved_images="$("${compose[@]}" --profile ingress config --images)"
grep -Fxq "$NGINX_IMAGE" <<<"$resolved_images" || fail "Compose does not resolve the configured nginx digest."

expected_nginx_id="$(docker image inspect "$NGINX_IMAGE" --format '{{.Id}}')"
running_nginx_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-ingress-1")"
[[ "$running_nginx_id" == "$expected_nginx_id" ]] || fail "running ingress image drifts from NGINX_IMAGE."

readonly_root="$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "${COMPOSE_PROJECT_NAME}-ingress-1")"
privileged="$(docker inspect -f '{{.HostConfig.Privileged}}' "${COMPOSE_PROJECT_NAME}-ingress-1")"
[[ "$readonly_root" == "true" && "$privileged" == "false" ]] ||   fail "ingress container hardening flags are incorrect."

ingress_networks="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${COMPOSE_PROJECT_NAME}-ingress-1")"
grep -qx "${COMPOSE_PROJECT_NAME}_agent_private" <<<"$ingress_networks" ||   fail "ingress is not attached to the private backend network."
grep -qx "${COMPOSE_PROJECT_NAME}_ingress_public" <<<"$ingress_networks" ||   fail "ingress is not attached to the public edge network."

n8n_networks="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${COMPOSE_PROJECT_NAME}-n8n-1")"
if grep -qx "${COMPOSE_PROJECT_NAME}_ingress_public" <<<"$n8n_networks"; then
  fail "Agent v2 n8n must not be attached to ingress_public."
fi

[[ "$(stat -c '%a' "$ROOT_DIR/deploy/tls/tls.crt")" == "600" ]] || fail "TLS certificate is not owner-only."
[[ "$(stat -c '%a' "$ROOT_DIR/deploy/tls/tls.key")" == "600" ]] || fail "TLS private key is not owner-only."
git -C "$ROOT_DIR" check-ignore -q deploy/tls/tls.crt || fail "TLS certificate is not Git-ignored."
git -C "$ROOT_DIR" check-ignore -q deploy/tls/tls.key || fail "TLS private key is not Git-ignored."

ss -ltn | grep -q "${INGRESS_BIND_ADDRESS}:${INGRESS_HTTP_PORT}[[:space:]]" ||   fail "HTTP ingress listener is missing."
ss -ltn | grep -q "${INGRESS_BIND_ADDRESS}:${INGRESS_HTTPS_PORT}[[:space:]]" ||   fail "HTTPS ingress listener is missing."

resolve=(--resolve "${PUBLIC_DOMAIN}:${INGRESS_HTTPS_PORT}:127.0.0.1")
http_resolve=(--resolve "${PUBLIC_DOMAIN}:${INGRESS_HTTP_PORT}:127.0.0.1")
https_base="https://${PUBLIC_DOMAIN}:${INGRESS_HTTPS_PORT}"
http_base="http://${PUBLIC_DOMAIN}:${INGRESS_HTTP_PORT}"

redirect_headers="$(mktemp)"
body="$(mktemp)"
guard_env="$(mktemp)"
guard_out="$(mktemp)"
cleanup() {
  rm -f "$redirect_headers" "$body" "$guard_env" "$guard_out"
}
trap cleanup EXIT

redirect_status="$(curl -sS "${http_resolve[@]}" -o /dev/null -D "$redirect_headers" -w '%{http_code}'   "$http_base/healthz")"
[[ "$redirect_status" == "308" ]] || fail "HTTP ingress did not return 308."
grep -qi "^Location: ${PUBLIC_HTTPS_ORIGIN}/healthz" "$redirect_headers" ||   fail "HTTP redirect target is incorrect."

health_status="$(curl -sS --cacert "$CERT" "${resolve[@]}" -o "$body" -w '%{http_code}'   "$https_base/healthz")"
[[ "$health_status" == "200" ]] || fail "HTTPS ingress health endpoint is not 200."
grep -qx 'ok' "$body" || fail "HTTPS ingress health body is unexpected."

root_status="$(curl -sS --cacert "$CERT" "${resolve[@]}" -o /dev/null -w '%{http_code}'   "$https_base/")"
[[ "$root_status" == "404" ]] || fail "n8n editor root is exposed through ingress."

signin_status="$(curl -sS --cacert "$CERT" "${resolve[@]}" -o /dev/null -w '%{http_code}'   "$https_base/signin")"
[[ "$signin_status" == "404" ]] || fail "n8n signin surface is exposed through ingress."

wrong_host_status="$(curl -sS --cacert "$CERT" -o /dev/null -w '%{http_code}'   "https://127.0.0.1:${INGRESS_HTTPS_PORT}/healthz")"
[[ "$wrong_host_status" == "404" ]] || fail "unexpected Host header was accepted by HTTPS ingress."

method_status="$(curl -sS --cacert "$CERT" "${resolve[@]}" -o /dev/null -w '%{http_code}'   "$https_base/webhook/revint/v2/deals")"
[[ "$method_status" == "405" ]] || fail "ingress does not enforce POST on deal ingestion."

unauth_deal_status="$(curl -sS --cacert "$CERT" "${resolve[@]}"   -H 'Content-Type: application/json'   -d '{}'   -o /dev/null -w '%{http_code}'   "$https_base/webhook/revint/v2/deals")"
[[ "$unauth_deal_status" == "403" ]] || fail "unauthenticated deal ingress was not rejected."

unauth_report_status="$(curl -sS --cacert "$CERT" "${resolve[@]}"   -H 'Content-Type: application/json'   -d '{}'   -o /dev/null -w '%{http_code}'   "$https_base/webhook/revint/v2/report")"
[[ "$unauth_report_status" == "403" ]] || fail "unauthenticated report ingress was not rejected."

bad_payload='{"source_record_id":"https-ingress-verify","amount":10,"currency_code":"'"$CLIENT_CURRENCY"'","stage_name":"Invalid","stage_category":"unknown"}'
auth_status="$(curl -sS --cacert "$CERT" "${resolve[@]}"   -H 'Content-Type: application/json'   -H "X-Revint-Ingest-Key: $REST_INGEST_API_KEY"   -d "$bad_payload"   -o "$body" -w '%{http_code}'   "$https_base/webhook/revint/v2/deals")"
[[ "$auth_status" == "400" ]] || fail "authenticated proxied validation did not reach the Agent v2 workflow."
grep -q 'STAGE_CATEGORY_INVALID' "$body" || fail "proxied validation response lost the governed error code."

nginx_config="$("${compose[@]}" --profile ingress exec -T ingress nginx -T 2>&1)"
grep -q 'ssl_protocols TLSv1.2 TLSv1.3;' <<<"$nginx_config" || fail "TLS protocol floor is not TLS 1.2."
[[ "$(grep -c 'proxy_pass http://n8n:5678;' <<<"$nginx_config")" -eq 2 ]] ||   fail "ingress exposes an unexpected number of n8n proxy routes."

ss -ltn | grep -q ':5678[[:space:]]' || fail "protected old n8n listener on 5678 is missing."
ss -ltn | grep -q '127.0.0.1:5681[[:space:]]' || fail "Agent v2 backend listener on 5681 is missing."

cp "$ENV_FILE" "$guard_env"
python3 - "$guard_env" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
updates = {
    "PUBLIC_DOMAIN": "example.invalid",
    "PUBLIC_HTTPS_ORIGIN": "https://example.invalid",
    "INGRESS_BIND_ADDRESS": "0.0.0.0",
    "INGRESS_HTTP_PORT": "80",
    "INGRESS_HTTPS_PORT": "443",
    "N8N_WEBHOOK_URL": "https://example.invalid/",
}
lines = p.read_text().splitlines()
seen = set()
out = []
for line in lines:
    key = line.split("=", 1)[0] if "=" in line and not line.lstrip().startswith("#") else None
    if key in updates:
        out.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")
p.write_text("\n".join(out) + "\n")
PY

if ENV_FILE="$guard_env" "$ROOT_DIR/scripts/deploy-https-ingress.sh"   --confirm-public WRONG_TOKEN >"$guard_out" 2>&1; then
  fail "public ingress accepted an invalid confirmation token."
fi
grep -q 'public ingress confirmation token is missing' "$guard_out" ||   fail "public ingress confirmation guard failed for an unexpected reason."

echo "PASS: HTTPS termination and HTTP-to-HTTPS redirect are active."
echo "PASS: nginx uses the configured immutable image digest."
echo "PASS: ingress container is read-only, non-privileged, and network-separated from n8n."
echo "PASS: TLS certificate/key are owner-only and excluded from Git."
echo "PASS: only the two authenticated Agent v2 webhook routes are proxied."
echo "PASS: n8n editor/signin surfaces remain blocked at the ingress boundary."
echo "PASS: header authentication and governed validation survive the TLS proxy."
echo "PASS: TLS is limited to 1.2/1.3 and security headers are configured."
echo "PASS: non-loopback public binding requires the explicit confirmation token."
echo "PASS: old n8n 5678 and Agent v2 backend 5681 remain available."

bash "$ROOT_DIR/scripts/verify-upgrade-rollback.sh"

echo "PASS: HTTPS and public-ingress stage verification passed."
