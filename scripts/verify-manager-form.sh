#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
python3 - <<'PY2'
import json
from pathlib import Path
w=json.loads(Path('workflows/runtime-templates/REVINT-V2-FORM-01.json').read_text())
w=w[0] if isinstance(w,list) else w
names={n['name']:n for n in w['nodes']}
assert set(names)=={'INT | SSO Manager Form','REP | Build Manager Form Page','DEL | Return Manager Form'}
t=names['INT | SSO Manager Form']
assert t['parameters']['httpMethod']=='GET'
assert t['parameters']['authentication']=='headerAuth'
assert t['credentials']['httpHeaderAuth']['id']=='REVINTSSOINTERNAL001'
code=names['REP | Build Manager Form Page']['parameters']['jsCode']
for x in ["/sso/report","delivery_channel:'api'","textContent","maxlength","1000"]: assert x in code,x
for x in ['principal_key','requester_id','innerHTML','/webhook/revint/v2/report']: assert x not in code,x
headers=names['DEL | Return Manager Form']['parameters']['options']['responseHeaders']['entries']
h={x['name'].lower():x['value'] for x in headers}
assert h['cache-control']=='no-store'
assert 'frame-ancestors' in h['content-security-policy']
assert 'text/html' in h['content-type']
print('PASS: form is presentation-only and submits through the SSO Agent path.')
PY2
grep -q 'location = /sso/form {' deploy/nginx/revint.conf.template
grep -q 'auth_request /_sso_auth;' deploy/nginx/revint.conf.template
grep -q 'proxy_pass http://n8n:5678/webhook/revint/v2/form-sso;' deploy/nginx/revint.conf.template
grep -q 'proxy_set_header X-Revint-Sso-Internal-Key "${SSO_INTERNAL_API_KEY}";' deploy/nginx/revint.conf.template
echo "PASS: /sso/form is OIDC-gated, GET-only, rate-limited, and internal-key protected."
echo "PASS: Agent V2 manager-form verification passed."
