#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"

TARGET_N8N=""
TARGET_POSTGRES=""
CONFIRM=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  bash scripts/upgrade-agent-v2.sh     --target-n8n 2.35.7     [--target-postgres 16-alpine]     --confirm REVINT_AGENT_V2_UPGRADE

Dry-run:
  bash scripts/upgrade-agent-v2.sh     --target-n8n 2.35.7     --dry-run
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

canonical_digest_ref() {
  local digest="$1"
  case "$digest" in
    docker.io/*) printf '%s
' "$digest" ;;
    n8nio/*) printf 'docker.io/%s
' "$digest" ;;
    postgres@*) printf 'docker.io/library/%s
' "$digest" ;;
    *) printf '%s
' "$digest" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-n8n)
      TARGET_N8N="${2:-}"
      shift 2
      ;;
    --target-postgres)
      TARGET_POSTGRES="${2:-}"
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

[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE does not exist."

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

CURRENT_N8N="${N8N_VERSION:-}"
CURRENT_POSTGRES="${POSTGRES_VERSION:-}"
CURRENT_N8N_IMAGE="${N8N_IMAGE:-}"
CURRENT_POSTGRES_IMAGE="${POSTGRES_IMAGE:-}"
TARGET_POSTGRES="${TARGET_POSTGRES:-$CURRENT_POSTGRES}"

[[ "$CURRENT_N8N_IMAGE" == *@sha256:* ]] || fail "current N8N_IMAGE is not immutable."
[[ "$CURRENT_POSTGRES_IMAGE" == *@sha256:* ]] || fail "current POSTGRES_IMAGE is not immutable."
[[ "$TARGET_N8N" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||   fail "--target-n8n must be an exact semantic version such as 2.35.7."
[[ "$TARGET_POSTGRES" =~ ^[0-9]+([.][0-9]+){0,2}(-[A-Za-z0-9._-]+)?$ ]] ||   fail "--target-postgres must be an explicit version tag."

current_pg_major="$(sed -E 's/^([0-9]+).*/\1/' <<<"$CURRENT_POSTGRES")"
target_pg_major="$(sed -E 's/^([0-9]+).*/\1/' <<<"$TARGET_POSTGRES")"
[[ "$current_pg_major" == "$target_pg_major" ]] ||   fail "automatic PostgreSQL major upgrades are prohibited ($CURRENT_POSTGRES -> $TARGET_POSTGRES)."

command -v docker >/dev/null || fail "docker is not available."
command -v python3 >/dev/null || fail "python3 is not available."

bash "$ROOT_DIR/scripts/healthcheck.sh" >/dev/null

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "PASS: upgrade preflight is valid."
  echo "CURRENT_N8N_VERSION=$CURRENT_N8N"
  echo "TARGET_N8N_VERSION=$TARGET_N8N"
  echo "CURRENT_POSTGRES_VERSION=$CURRENT_POSTGRES"
  echo "TARGET_POSTGRES_VERSION=$TARGET_POSTGRES"
  echo "CURRENT_N8N_IMAGE=$CURRENT_N8N_IMAGE"
  echo "CURRENT_POSTGRES_IMAGE=$CURRENT_POSTGRES_IMAGE"
  echo "VERSION_LABEL_CHANGE=$([[ "$CURRENT_N8N" == "$TARGET_N8N" && "$CURRENT_POSTGRES" == "$TARGET_POSTGRES" ]] && echo false || echo true)"
  echo "NOTE=Target digests are resolved only during a confirmed upgrade."
  exit 0
fi

[[ "$CONFIRM" == "REVINT_AGENT_V2_UPGRADE" ]] || {
  usage
  fail "upgrade confirmation token is missing."
}

checkpoint_output="$(bash "$ROOT_DIR/scripts/create-release-checkpoint.sh")"
checkpoint_path="$(awk -F= '$1=="CHECKPOINT_PATH" {print $2}' <<<"$checkpoint_output" | tail -1)"
backup_path="$(awk -F= '$1=="BACKUP_PATH" {print $2}' <<<"$checkpoint_output" | tail -1)"
[[ -d "$checkpoint_path" && -d "$backup_path" ]] || fail "release checkpoint creation failed."

n8n_target_tag="docker.io/n8nio/n8n:$TARGET_N8N"
postgres_target_tag="docker.io/library/postgres:$TARGET_POSTGRES"

echo "Pulling target tags to resolve immutable deployment digests..."
docker pull "$n8n_target_tag" >/dev/null
docker pull "$postgres_target_tag" >/dev/null

n8n_target_repo_digest="$(docker image inspect "$n8n_target_tag" --format '{{index .RepoDigests 0}}')"
postgres_target_repo_digest="$(docker image inspect "$postgres_target_tag" --format '{{index .RepoDigests 0}}')"
[[ -n "$n8n_target_repo_digest" && "$n8n_target_repo_digest" != "<no value>" ]] || fail "target n8n image digest is unavailable."
[[ -n "$postgres_target_repo_digest" && "$postgres_target_repo_digest" != "<no value>" ]] || fail "target PostgreSQL image digest is unavailable."

n8n_target_image="$(canonical_digest_ref "$n8n_target_repo_digest")"
postgres_target_image="$(canonical_digest_ref "$postgres_target_repo_digest")"
n8n_target_id="$(docker image inspect "$n8n_target_image" --format '{{.Id}}')"
postgres_target_id="$(docker image inspect "$postgres_target_image" --format '{{.Id}}')"

cat > "$checkpoint_path/upgrade-target.env" <<EOF
TARGET_N8N_VERSION=$TARGET_N8N
TARGET_POSTGRES_VERSION=$TARGET_POSTGRES
TARGET_N8N_DEPLOY_IMAGE=$n8n_target_image
TARGET_POSTGRES_DEPLOY_IMAGE=$postgres_target_image
TARGET_N8N_IMAGE_ID=$n8n_target_id
TARGET_POSTGRES_IMAGE_ID=$postgres_target_id
EOF
chmod 600 "$checkpoint_path/upgrade-target.env"
(
  cd "$checkpoint_path"
  sha256sum release.env upgrade-target.env > SHA256SUMS
)

python3 - "$ENV_FILE" "$TARGET_N8N" "$TARGET_POSTGRES" "$n8n_target_image" "$postgres_target_image" <<'PY'
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
    raise SystemExit(f"runtime pin update failed: {seen}")
path.write_text("\n".join(out) + "\n")
PY

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

upgrade_ok=0
cleanup() {
  if [[ "$upgrade_ok" -ne 1 ]]; then
    echo "WARNING: upgrade did not complete successfully." >&2
    echo "CHECKPOINT_PATH=$checkpoint_path" >&2
    echo "ROLLBACK_COMMAND=bash scripts/rollback-agent-v2.sh --checkpoint '$checkpoint_path' --confirm REVINT_AGENT_V2_ROLLBACK" >&2
  fi
}
trap cleanup EXIT

echo "Applying immutable target images and waiting for health..."
"${compose[@]}" up -d --wait

n8n_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-n8n-1")"
n8n_db_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-n8n-db-1")"
reporting_db_running_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-reporting-db-1")"

[[ "$n8n_running_id" == "$n8n_target_id" ]] || fail "running n8n image ID does not match the resolved target digest."
[[ "$n8n_db_running_id" == "$postgres_target_id" && "$reporting_db_running_id" == "$postgres_target_id" ]] ||   fail "running PostgreSQL image IDs do not match the resolved target digest."

bash "$ROOT_DIR/scripts/healthcheck.sh"
bash "$ROOT_DIR/scripts/verify-backup-recovery-stage.sh"

upgrade_ok=1
trap - EXIT

echo "PASS: Agent v2 upgrade completed with immutable image pins and full regression."
echo "CHECKPOINT_PATH=$checkpoint_path"
echo "PRE_UPGRADE_BACKUP=$backup_path"
echo "N8N_VERSION=$TARGET_N8N"
echo "POSTGRES_VERSION=$TARGET_POSTGRES"
echo "N8N_IMAGE=$n8n_target_image"
echo "POSTGRES_IMAGE=$postgres_target_image"
