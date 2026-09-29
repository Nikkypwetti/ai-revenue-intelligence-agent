#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/deploy/.env}"
CONFIG="${CONNECTOR_CONFIG_FILE:-$ROOT_DIR/config/salesforce-connector.example.json}"

[[ -f "$ENV_FILE" ]] || { echo "FAIL: $ENV_FILE does not exist."; exit 1; }
[[ -f "$CONFIG" ]] || { echo "FAIL: Salesforce connector config is missing."; exit 1; }

bash "$ROOT_DIR/scripts/init-multi-crm-sync.sh"
CONNECTOR_CONFIG_FILE="$CONFIG" bash "$ROOT_DIR/scripts/apply-connector-config.sh"

echo "PASS: Salesforce connector mapping and disabled reliability policy initialized."
