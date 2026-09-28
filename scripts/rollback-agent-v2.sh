#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"

CHECKPOINT_PATH=""
CONFIRM=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  bash scripts/rollback-agent-v2.sh     --checkpoint backups/checkpoints/<timestamp>     --confirm REVINT_AGENT_V2_ROLLBACK

Dry-run:
  bash scripts/rollback-agent-v2.sh     --checkpoint backups/checkpoints/<timestamp>     --dry-run
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

manifest_value() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkpoint)
      CHECKPOINT_PATH="${2:-}"
      shift 2
      ;;
    --confirm)
      CONFIRM="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

[[ -n "$CHECKPOINT_PATH" ]] || fail "--checkpoint is required."
CHECKPOINT_PATH="$(readlink -f "$CHECKPOINT_PATH")"
[[ -d "$CHECKPOINT_PATH" ]] || fail "checkpoint directory does not exist."
[[ -f "$CHECKPOINT_PATH/release.env" && -f "$CHECKPOINT_PATH/SHA256SUMS" ]] ||   fail "checkpoint metadata is incomplete."

(
  cd "$CHECKPOINT_PATH"
  sha256sum -c SHA256SUMS
) >/dev/null

release_file="$CHECKPOINT_PATH/release.env"
format_version="$(manifest_value "$release_file" CHECKPOINT_FORMAT_VERSION)"
checkpoint_project="$(manifest_value "$release_file" COMPOSE_PROJECT_NAME)"
checkpoint_git="$(manifest_value "$release_file" SOURCE_GIT_COMMIT)"
old_n8n_version="$(manifest_value "$release_file" N8N_VERSION)"
old_postgres_version="$(manifest_value "$release_file" POSTGRES_VERSION)"
old_n8n_deploy_image="$(manifest_value "$release_file" N8N_DEPLOY_IMAGE)"
old_postgres_deploy_image="$(manifest_value "$release_file" POSTGRES_DEPLOY_IMAGE)"
old_n8n_image_id="$(manifest_value "$release_file" N8N_IMAGE_ID)"
old_postgres_image_id="$(manifest_value "$release_file" POSTGRES_IMAGE_ID)"
old_n8n_digest="$(manifest_value "$release_file" N8N_REPO_DIGEST)"
old_postgres_digest="$(manifest_value "$release_file" POSTGRES_REPO_DIGEST)"
backup_path="$(manifest_value "$release_file" BACKUP_PATH)"

[[ "$format_version" == "2" ]] || fail "unsupported checkpoint format version; create a new immutable-image checkpoint."
[[ "$old_n8n_deploy_image" == *@sha256:* ]] || fail "checkpoint n8n deployment image is not immutable."
[[ "$old_postgres_deploy_image" == *@sha256:* ]] || fail "checkpoint PostgreSQL deployment image is not immutable."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."
[[ -d "$backup_path" ]] || fail "checkpoint backup no longer exists."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ "$checkpoint_project" == "$COMPOSE_PROJECT_NAME" ]] ||   fail "checkpoint project does not match current deployment."
[[ "${N8N_IMAGE:-}" == *@sha256:* && "${POSTGRES_IMAGE:-}" == *@sha256:* ]] ||   fail "current deployment is not using immutable image pins."

current_pg_major="$(sed -E 's/^([0-9]+).*/\1/' <<<"$POSTGRES_VERSION")"
old_pg_major="$(sed -E 's/^([0-9]+).*/\1/' <<<"$old_postgres_version")"
[[ "$current_pg_major" == "$old_pg_major" ]] ||   fail "automatic rollback across PostgreSQL major versions is prohibited."

for value in   "$old_n8n_version" "$old_postgres_version"   "$old_n8n_deploy_image" "$old_postgres_deploy_image"   "$old_n8n_image_id" "$old_postgres_image_id"   "$old_n8n_digest" "$old_postgres_digest"; do
  [[ -n "$value" ]] || fail "checkpoint is missing required rollback metadata."
done

if [[ "$DRY_RUN" -ne 1 && "$CONFIRM" != "REVINT_AGENT_V2_ROLLBACK" ]]; then
  usage
  fail "rollback confirmation token is missing."
fi

bash "$ROOT_DIR/scripts/verify-backup-recovery.sh" "$backup_path" >/dev/null

if [[ "$DRY_RUN" -eq 1 ]]; then
  docker image inspect "$old_n8n_deploy_image" >/dev/null 2>&1 ||     echo "NOTE: checkpoint n8n digest is not currently cached and would be pulled during rollback."
  docker image inspect "$old_postgres_deploy_image" >/dev/null 2>&1 ||     echo "NOTE: checkpoint PostgreSQL digest is not currently cached and would be pulled during rollback."
  echo "PASS: rollback checkpoint, immutable image refs, and recovery backup are valid."
  echo "CHECKPOINT_GIT_COMMIT=$checkpoint_git"
  echo "ROLLBACK_N8N_VERSION=$old_n8n_version"
  echo "ROLLBACK_POSTGRES_VERSION=$old_postgres_version"
  echo "ROLLBACK_N8N_IMAGE=$old_n8n_deploy_image"
  echo "ROLLBACK_POSTGRES_IMAGE=$old_postgres_deploy_image"
  echo "BACKUP_PATH=$backup_path"
  exit 0
fi

echo "Pulling exact checkpoint image digests..."
docker pull "$old_n8n_deploy_image" >/dev/null
docker pull "$old_postgres_deploy_image" >/dev/null

resolved_n8n_id="$(docker image inspect "$old_n8n_deploy_image" --format '{{.Id}}')"
resolved_postgres_id="$(docker image inspect "$old_postgres_deploy_image" --format '{{.Id}}')"
[[ "$resolved_n8n_id" == "$old_n8n_image_id" ]] ||   fail "checkpoint n8n image ID could not be restored exactly."
[[ "$resolved_postgres_id" == "$old_postgres_image_id" ]] ||   fail "checkpoint PostgreSQL image ID could not be restored exactly."

python3 - "$ENV_FILE" "$old_n8n_version" "$old_postgres_version" "$old_n8n_deploy_image" "$old_postgres_deploy_image" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
values = {
    "N8N_VERSION": sys.argv[2],
    "POSTGRES_VERSION": sys.argv[3],
    "N8N_IMAGE": sys.argv[4],
    "POSTGRES_IMAGE": sys.argv[5],
}
lines = path.read_text().splitlines()
seen = {k: 0 for k in values}
out = []
for line in lines:
    key = line.split("=", 1)[0] if "=" in line else None
    if key in values:
        out.append(f"{key}={values[key]}")
        seen[key] += 1
    else:
        out.append(line)
if any(count != 1 for count in seen.values()):
    raise SystemExit(f"runtime pin rollback failed: {seen}")
path.write_text("\n".join(out) + "\n")
PY

bash "$ROOT_DIR/scripts/restore-agent-v2.sh"   --backup "$backup_path"   --confirm REVINT_AGENT_V2_LIVE_RESTORE

n8n_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-n8n-1")"
n8n_db_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-n8n-db-1")"
reporting_db_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-reporting-db-1")"

[[ "$n8n_running_id" == "$old_n8n_image_id" ]] || fail "rolled-back n8n image ID does not match checkpoint."
[[ "$n8n_db_running_id" == "$old_postgres_image_id" && "$reporting_db_running_id" == "$old_postgres_image_id" ]] ||   fail "rolled-back PostgreSQL image IDs do not match checkpoint."

bash "$ROOT_DIR/scripts/verify-backup-recovery-stage.sh"

echo "PASS: Agent v2 rollback completed to exact checkpoint images/data with full regression."
echo "ROLLED_BACK_TO_CHECKPOINT=$CHECKPOINT_PATH"
echo "N8N_VERSION=$old_n8n_version"
echo "POSTGRES_VERSION=$old_postgres_version"
echo "N8N_IMAGE=$old_n8n_deploy_image"
echo "POSTGRES_IMAGE=$old_postgres_deploy_image"
