#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
POSTGRES17_IMAGE="${POSTGRES17_IMAGE:-}"
CONFIRM=""
KEEP=0

usage(){
  cat <<'EOF'
Usage:
  POSTGRES17_IMAGE=docker.io/library/postgres@sha256:<digest> \
  bash scripts/verify-postgres17-migration.sh --confirm REVINT_PG17_DRILL [--keep]

This performs an isolated logical dump/restore drill. It does NOT cut over the live databases.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "FAIL: unknown argument $1" >&2; exit 1 ;;
  esac
done

[[ "$CONFIRM" == "REVINT_PG17_DRILL" ]] || { usage; echo "FAIL: explicit drill confirmation required." >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE missing." >&2; exit 1; }
[[ "$POSTGRES17_IMAGE" == *@sha256:* ]] || { echo "FAIL: POSTGRES17_IMAGE must be digest-pinned." >&2; exit 1; }

set -a
source "$ENV_FILE"
set +a

current_major="${POSTGRES_VERSION%%-*}"
current_major="${current_major%%.*}"
[[ "$current_major" == "16" ]] || { echo "FAIL: this drill expects a PostgreSQL 16 source, got $POSTGRES_VERSION." >&2; exit 1; }

command -v docker >/dev/null || { echo "FAIL: docker missing." >&2; exit 1; }

backup_output="$(bash "$ROOT_DIR/scripts/backup-agent-v2.sh")"
printf '%s\n' "$backup_output"
backup_path="$(awk -F= '$1=="BACKUP_PATH" {print $2}' <<<"$backup_output" | tail -1)"
[[ -d "$backup_path" ]] || { echo "FAIL: backup not created." >&2; exit 1; }

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
network="revint-pg17-drill-$run_id"
n8n_name="revint-pg17-n8n-$run_id"
report_name="revint-pg17-report-$run_id"
password="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"

cleanup(){
  if [[ "$KEEP" -eq 0 ]]; then
    docker rm -f "$n8n_name" "$report_name" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
  else
    echo "KEEP_N8N_CONTAINER=$n8n_name"
    echo "KEEP_REPORTING_CONTAINER=$report_name"
  fi
}
trap cleanup EXIT

docker pull "$POSTGRES17_IMAGE" >/dev/null
major="$(docker run --rm "$POSTGRES17_IMAGE" postgres --version | sed -E 's/.* ([0-9]+).*/\1/')"
[[ "$major" == "17" ]] || { echo "FAIL: target image is PostgreSQL $major, expected 17." >&2; exit 1; }

docker network create "$network" >/dev/null

start_pg(){
  local name="$1" db="$2" user="$3"
  docker run -d --name "$name" --network "$network" \
    -e POSTGRES_DB="$db" -e POSTGRES_USER="$user" -e POSTGRES_PASSWORD="$password" \
    "$POSTGRES17_IMAGE" >/dev/null
  for i in $(seq 1 40); do
    if docker exec "$name" pg_isready -U "$user" -d "$db" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  return 1
}

start_pg "$n8n_name" "$N8N_DB_NAME" "$N8N_DB_USER"
start_pg "$report_name" "$REPORTING_DB_NAME" "$REPORTING_DB_ADMIN_USER"

cat "$backup_path/n8n-db.dump" | docker exec -i "$n8n_name" pg_restore \
  -U "$N8N_DB_USER" -d "$N8N_DB_NAME" --no-owner --no-privileges --exit-on-error

cat "$backup_path/reporting-db.dump" | docker exec -i "$report_name" pg_restore \
  -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" --no-owner --no-privileges --exit-on-error

n8n_workflows="$(docker exec "$n8n_name" psql -X -q -A -t -U "$N8N_DB_USER" -d "$N8N_DB_NAME" -c 'SELECT count(*) FROM workflow_entity;')"
report_kpis="$(docker exec "$report_name" psql -X -q -A -t -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c 'SELECT count(*) FROM governance.kpi_catalog;')"
report_deals="$(docker exec "$report_name" psql -X -q -A -t -U "$REPORTING_DB_ADMIN_USER" -d "$REPORTING_DB_NAME" -c 'SELECT count(*) FROM reporting.deals;')"

[[ "$n8n_workflows" =~ ^[0-9]+$ && "$n8n_workflows" -gt 0 ]] || { echo "FAIL: restored n8n workflow count invalid." >&2; exit 1; }
[[ "$report_kpis" =~ ^[0-9]+$ && "$report_kpis" -ge 37 ]] || { echo "FAIL: restored KPI catalogue invalid." >&2; exit 1; }
[[ "$report_deals" =~ ^[0-9]+$ ]] || { echo "FAIL: restored deal count invalid." >&2; exit 1; }

echo "PASS: PostgreSQL 17 isolated logical restore drill succeeded."
echo "SOURCE_BACKUP=$backup_path"
echo "RESTORED_N8N_WORKFLOWS=$n8n_workflows"
echo "RESTORED_KPIS=$report_kpis"
echo "RESTORED_DEALS=$report_deals"
echo "NOTE=Live PostgreSQL 16 databases were not modified."
