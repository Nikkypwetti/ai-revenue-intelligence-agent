#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

git diff --check

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find scripts -maxdepth 1 -type f -name '*.sh' -print0)

python3 - <<'PY'
import json,re
from pathlib import Path
root=Path('.')
files=list((root/'workflows/runtime-templates').glob('*.json'))
files += [root/'config/connectors.example.json',root/'config/clients/client-deployment.example.json']
for path in files:
    json.loads(path.read_text())
for path in (root/'workflows/runtime-templates').glob('*.json'):
    text=path.read_text()
    assert not re.search(r'(?i)bearer\s+[A-Za-z0-9._-]{12,}',text),path
    assert not re.search(r'gsk_[A-Za-z0-9_-]{12,}',text),path
for path in (root/'workflows/runtime-templates').glob('*.json'):
    doc=json.loads(path.read_text())
    w=doc[0] if isinstance(doc,list) else doc
    names={n['name'] for n in w.get('nodes',[])}
    assert len(names)==len(w.get('nodes',[])),path
    for source,groups in w.get('connections',{}).items():
        assert source in names,(path,source)
        for outputs in groups.values():
            for group in outputs:
                for edge in group:
                    assert edge['node'] in names,(path,edge['node'])
print('PASS: JSON/templates parse, workflow graphs close, and no obvious bearer/Groq secret is embedded.')
PY

grep -q "automatic PostgreSQL major upgrades are prohibited" scripts/upgrade-agent-v2.sh
grep -q "REVINTSALESFORCERO001" workflows/runtime-templates/REVINT-V2-SALESFORCE-01.json
grep -q "REVINTAIRTABLE001" workflows/runtime-templates/REVINT-V2-AIRTABLE-01.json

echo "PASS: static Agent V2 CI validation passed."

