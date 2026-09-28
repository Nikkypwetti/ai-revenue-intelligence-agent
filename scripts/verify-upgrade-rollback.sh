#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/deploy/docker-compose.yml}"
BACKUP_ROOT="${BACKUP_ROOT:-$ROOT_DIR/backups}"
CHECKPOINT_ROOT="${CHECKPOINT_ROOT:-$BACKUP_ROOT/checkpoints}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

manifest_value() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file"
}

cd "$ROOT_DIR"

for script in   scripts/create-release-checkpoint.sh   scripts/upgrade-agent-v2.sh   scripts/rollback-agent-v2.sh   scripts/validate-deployment.sh; do
  bash -n "$script"
done

git diff --check
bash scripts/validate-deployment.sh >/dev/null

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ "$N8N_IMAGE" == *@sha256:* ]] || fail "N8N_IMAGE is not immutable."
[[ "$POSTGRES_IMAGE" == *@sha256:* ]] || fail "POSTGRES_IMAGE is not immutable."

compose=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

resolved_images="$("${compose[@]}" config --images)"
grep -Fxq "$N8N_IMAGE" <<<"$resolved_images" || fail "Compose does not resolve the configured n8n digest."
[[ "$(grep -Fxc "$POSTGRES_IMAGE" <<<"$resolved_images")" -eq 2 ]] ||   fail "Compose does not resolve the configured PostgreSQL digest for both database services."

expected_n8n_id="$(docker image inspect "$N8N_IMAGE" --format '{{.Id}}')"
expected_postgres_id="$(docker image inspect "$POSTGRES_IMAGE" --format '{{.Id}}')"
running_n8n_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-n8n-1")"
running_n8n_db_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-n8n-db-1")"
running_reporting_db_id="$(docker inspect -f '{{.Image}}' "${COMPOSE_PROJECT_NAME}-reporting-db-1")"

[[ "$running_n8n_id" == "$expected_n8n_id" ]] || fail "running n8n image drifts from N8N_IMAGE."
[[ "$running_n8n_db_id" == "$expected_postgres_id" && "$running_reporting_db_id" == "$expected_postgres_id" ]] ||   fail "running PostgreSQL images drift from POSTGRES_IMAGE."

latest="$(find "$CHECKPOINT_ROOT" -mindepth 1 -maxdepth 1 -type d   -name '20??????T??????Z' -printf '%f
' 2>/dev/null | sort | tail -1)"
[[ -n "$latest" ]] || fail "no release checkpoint exists."
checkpoint="$CHECKPOINT_ROOT/$latest"

[[ "$(stat -c '%a' "$checkpoint")" == "700" ]] || fail "checkpoint directory is not mode 700."
while IFS= read -r artifact; do
  [[ "$(stat -c '%a' "$artifact")" == "600" ]] || fail "checkpoint artifact is not mode 600: $artifact"
done < <(find "$checkpoint" -mindepth 1 -maxdepth 1 -type f -print)

(
  cd "$checkpoint"
  sha256sum -c SHA256SUMS
) >/dev/null

release_file="$checkpoint/release.env"
[[ "$(manifest_value "$release_file" CHECKPOINT_FORMAT_VERSION)" == "2" ]] || fail "latest checkpoint is not format 2."
[[ "$(manifest_value "$release_file" COMPOSE_PROJECT_NAME)" == "$COMPOSE_PROJECT_NAME" ]] || fail "checkpoint project mismatch."
[[ "$(manifest_value "$release_file" N8N_DEPLOY_IMAGE)" == *@sha256:* ]] || fail "checkpoint n8n image is not immutable."
[[ "$(manifest_value "$release_file" POSTGRES_DEPLOY_IMAGE)" == *@sha256:* ]] || fail "checkpoint PostgreSQL image is not immutable."

bash scripts/rollback-agent-v2.sh --checkpoint "$checkpoint" --dry-run >/dev/null
bash scripts/upgrade-agent-v2.sh   --target-n8n "$N8N_VERSION"   --target-postgres "$POSTGRES_VERSION"   --dry-run >/dev/null

current_pg_major="$(sed -E 's/^([0-9]+).*/\1/' <<<"$POSTGRES_VERSION")"
next_pg_major="$((10#$current_pg_major + 1))"

if bash scripts/upgrade-agent-v2.sh   --target-n8n "$N8N_VERSION"   --target-postgres "$next_pg_major-alpine"   --dry-run >/tmp/revint-upgrade-major-guard.out 2>&1; then
  fail "automatic PostgreSQL major upgrade was accepted."
fi
grep -q 'automatic PostgreSQL major upgrades are prohibited' /tmp/revint-upgrade-major-guard.out ||   fail "PostgreSQL major-upgrade guard failed for an unexpected reason."
rm -f /tmp/revint-upgrade-major-guard.out

if bash scripts/upgrade-agent-v2.sh   --target-n8n "$N8N_VERSION"   --confirm WRONG_TOKEN >/tmp/revint-upgrade-confirm-guard.out 2>&1; then
  fail "invalid upgrade confirmation token was accepted."
fi
grep -q 'upgrade confirmation token is missing' /tmp/revint-upgrade-confirm-guard.out ||   fail "upgrade confirmation guard failed for an unexpected reason."
rm -f /tmp/revint-upgrade-confirm-guard.out

if bash scripts/rollback-agent-v2.sh   --checkpoint "$checkpoint"   --confirm WRONG_TOKEN >/tmp/revint-rollback-confirm-guard.out 2>&1; then
  fail "invalid rollback confirmation token was accepted."
fi
grep -q 'rollback confirmation token is missing' /tmp/revint-rollback-confirm-guard.out ||   fail "rollback confirmation guard failed for an unexpected reason."
rm -f /tmp/revint-rollback-confirm-guard.out

before="$(docker inspect -f '{{.Name}}|{{.Created}}|{{.Image}}'   "${COMPOSE_PROJECT_NAME}-n8n-1"   "${COMPOSE_PROJECT_NAME}-n8n-db-1"   "${COMPOSE_PROJECT_NAME}-reporting-db-1")"
"${compose[@]}" up -d --wait >/dev/null
after="$(docker inspect -f '{{.Name}}|{{.Created}}|{{.Image}}'   "${COMPOSE_PROJECT_NAME}-n8n-1"   "${COMPOSE_PROJECT_NAME}-n8n-db-1"   "${COMPOSE_PROJECT_NAME}-reporting-db-1")"
[[ "$before" == "$after" ]] || fail "unchanged immutable image pins caused container recreation."

ss -ltn | grep -q ':5678[[:space:]]' || fail "protected old n8n listener on 5678 is missing."
ss -ltn | grep -q '127.0.0.1:5681[[:space:]]' || fail "Agent v2 listener on 5681 is missing."

echo "PASS: Compose and running containers use immutable image digests."
echo "PASS: release checkpoint is checksum-protected, owner-only, and format 2."
echo "PASS: upgrade dry-run and PostgreSQL-major guard passed."
echo "PASS: rollback dry-run and confirmation guards passed."
echo "PASS: unchanged immutable pins cause zero container recreation."
echo "PASS: old n8n 5678 and Agent v2 5681 isolation remains intact."

bash "$ROOT_DIR/scripts/verify-backup-recovery-stage.sh"

echo "PASS: upgrade and rollback stage verification passed."
