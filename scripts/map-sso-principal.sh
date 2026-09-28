#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

principal=""
provider=""
subject=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/map-sso-principal.sh     --principal <existing-principal-key>     --provider <identity-provider-key>     --subject <stable-oidc-subject>

This only links an existing internal principal to an external identity.
It does not create principals, roles, or departments.
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --principal) principal="${2:-}"; shift 2 ;;
    --provider) provider="${2:-}"; shift 2 ;;
    --subject) subject="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$principal" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:@-]{0,127}$ ]] || fail "invalid principal key."
[[ "$provider" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || fail "invalid provider key."
[[ -n "$subject" && ${#subject} -le 512 ]] || fail "invalid external subject."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

result="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T reporting-db   psql -X -q -A -t -v ON_ERROR_STOP=1   -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME"   --set=principal="$principal" --set=provider="$provider" --set=subject="$subject" <<'SQL'
WITH updated AS (
  UPDATE governance.principal_registry
  SET identity_provider = :'provider',
      external_subject = :'subject',
      updated_at = now()
  WHERE principal_key = :'principal'
  RETURNING principal_key
)
SELECT count(*) FROM updated;
SQL
)"

[[ "$result" == "1" ]] || fail "principal does not exist or mapping was not applied."

echo "PASS: existing principal mapped to external identity."
echo "PRINCIPAL_KEY=$principal"
echo "IDENTITY_PROVIDER=$provider"
