#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE does not exist."
  echo "Run: cp deploy/.env.example deploy/.env"
  exit 1
fi

if grep -Eq '(^|=)CHANGE_ME' "$ENV_FILE"; then
  echo "FAIL: deploy/.env still contains CHANGE_ME placeholders."
  exit 1
fi

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet

echo "PASS: Docker Compose configuration is valid and secret placeholders were replaced."
