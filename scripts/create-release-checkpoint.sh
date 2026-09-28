#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"
CHECKPOINT_ROOT="${CHECKPOINT_ROOT:-$BACKUP_ROOT/checkpoints}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
command -v docker >/dev/null || fail "docker is not available."
command -v sha256sum >/dev/null || fail "sha256sum is not available."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for name in COMPOSE_PROJECT_NAME N8N_VERSION POSTGRES_VERSION N8N_IMAGE POSTGRES_IMAGE; do
  [[ -n "${!name:-}" && "${!name}" != CHANGE_ME* ]] || fail "$name is missing or invalid."
done

[[ "$N8N_IMAGE" == *@sha256:* ]] || fail "N8N_IMAGE must be pinned by immutable sha256 digest."
[[ "$POSTGRES_IMAGE" == *@sha256:* ]] || fail "POSTGRES_IMAGE must be pinned by immutable sha256 digest."

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

bash "$ROOT_DIR/scripts/healthcheck.sh" >/dev/null

n8n_configured_id="$(docker image inspect "$N8N_IMAGE" --format '{{.Id}}')"
postgres_configured_id="$(docker image inspect "$POSTGRES_IMAGE" --format '{{.Id}}')"
n8n_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-n8n-1")"
n8n_db_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-n8n-db-1")"
reporting_db_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-reporting-db-1")"

[[ "$n8n_running_id" == "$n8n_configured_id" ]] ||   fail "running n8n image does not match immutable N8N_IMAGE pin."
[[ "$n8n_db_running_id" == "$postgres_configured_id" && "$reporting_db_running_id" == "$postgres_configured_id" ]] ||   fail "running PostgreSQL images do not match immutable POSTGRES_IMAGE pin."

backup_output="$(BACKUP_ROOT="$BACKUP_ROOT" bash "$ROOT_DIR/scripts/backup-agent-v2.sh")"
backup_path="$(awk -F= '$1=="BACKUP_PATH" {print $2}' <<<"$backup_output" | tail -1)"
[[ -d "$backup_path" ]] || fail "verified backup was not created."

bash "$ROOT_DIR/scripts/verify-backup-recovery.sh" "$backup_path" >/dev/null

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
checkpoint_dir="$CHECKPOINT_ROOT/$timestamp"
mkdir -p "$CHECKPOINT_ROOT"
chmod 700 "$CHECKPOINT_ROOT"
mkdir -m 700 "$checkpoint_dir"

git_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
compose_sha256="$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')"

n8n_repo_digest="$(docker image inspect "$N8N_IMAGE" --format '{{index .RepoDigests 0}}')"
postgres_repo_digest="$(docker image inspect "$POSTGRES_IMAGE" --format '{{index .RepoDigests 0}}')"

[[ -n "$n8n_repo_digest" && "$n8n_repo_digest" != "<no value>" ]] ||   fail "n8n image does not have an immutable repo digest."
[[ -n "$postgres_repo_digest" && "$postgres_repo_digest" != "<no value>" ]] ||   fail "PostgreSQL image does not have an immutable repo digest."

cat > "$checkpoint_dir/release.env" <<EOF
CHECKPOINT_FORMAT_VERSION=2
CHECKPOINT_CREATED_AT_UTC=$timestamp
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
SOURCE_GIT_COMMIT=$git_commit
COMPOSE_FILE_SHA256=$compose_sha256
N8N_VERSION=$N8N_VERSION
POSTGRES_VERSION=$POSTGRES_VERSION
N8N_DEPLOY_IMAGE=$N8N_IMAGE
POSTGRES_DEPLOY_IMAGE=$POSTGRES_IMAGE
N8N_IMAGE_ID=$n8n_configured_id
POSTGRES_IMAGE_ID=$postgres_configured_id
N8N_REPO_DIGEST=$n8n_repo_digest
POSTGRES_REPO_DIGEST=$postgres_repo_digest
BACKUP_PATH=$backup_path
EOF

(
  cd "$checkpoint_dir"
  sha256sum release.env > SHA256SUMS
)

echo "PASS: release checkpoint created with immutable image pins and verified recovery backup."
echo "CHECKPOINT_PATH=$checkpoint_dir"
echo "BACKUP_PATH=$backup_path"
