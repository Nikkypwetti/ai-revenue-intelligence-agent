#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE does not exist."
  echo "Copy deploy/.env.example to deploy/.env and configure it first."
  exit 1
fi

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

echo "Container status:"
"${compose[@]}" ps

check_service() {
  local service="$1"
  local container_id
  local state

  container_id="$("${compose[@]}" ps -q "$service")"
  if [[ -z "$container_id" ]]; then
    echo "FAIL: $service has no running container."
    return 1
  fi

  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"

  if [[ "$state" != "healthy" && "$state" != "running" ]]; then
    echo "FAIL: $service state is $state."
    return 1
  fi

  echo "PASS: $service is $state."
}

check_service n8n-db
check_service reporting-db
check_service n8n

echo "PASS: Stage 1 deployment health checks passed."
