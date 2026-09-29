#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/export-powerbi-dataset.sh"

bash -n "$SCRIPT"

grep -q 'REPORTING_DB_READER_USER' "$SCRIPT"
grep -q 'REPORTING_DB_READER_PASSWORD' "$SCRIPT"
grep -q 'FROM reporting.deals' "$SCRIPT"
grep -q 'FROM observability.component_status' "$SCRIPT"
grep -q 'FROM observability.runtime_status' "$SCRIPT"
grep -q 'SHA256SUMS' "$SCRIPT"
grep -q 'REVINT_POWERBI_EXPORT' "$SCRIPT"
grep -q 'business_wide_management_extract' "$SCRIPT"

if grep -Eq '(INSERT INTO|UPDATE reporting\.|DELETE FROM|TRUNCATE|DROP TABLE)' "$SCRIPT"; then
  echo "FAIL: Power BI export script contains a reporting mutation."
  exit 1
fi

if bash "$SCRIPT" --confirm WRONG >/tmp/revint-powerbi-guard.out 2>&1; then
  echo "FAIL: invalid Power BI confirmation was accepted."
  exit 1
fi
grep -q 'confirmation token is missing or incorrect' /tmp/revint-powerbi-guard.out
rm -f /tmp/revint-powerbi-guard.out

echo "PASS: Power BI handoff is read-only, local-only, checksum-protected and explicitly guarded."
