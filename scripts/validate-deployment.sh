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

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ "${N8N_IMAGE:-}" != *@sha256:* ]]; then
  echo "FAIL: N8N_IMAGE must use an immutable sha256 digest."
  exit 1
fi

if [[ "${POSTGRES_IMAGE:-}" != *@sha256:* ]]; then
  echo "FAIL: POSTGRES_IMAGE must use an immutable sha256 digest."
  exit 1
fi

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet

echo "PASS: Docker Compose configuration is valid, secrets are populated, and runtime images are digest-pinned."
