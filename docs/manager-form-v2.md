# Agent V2 — SSO Manager Form

This adapter migrates the useful manager-form experience from the earlier REVINT-06 workflow without restoring V1 reporting logic.

## Architecture

browser -> /sso/form -> OIDC/SSO -> static V2 form -> /sso/report -> tenant-scoped principal -> RBAC + 37-KPI governance -> governed result

The browser never supplies principal_key, role, tenant, SQL, database identifiers, or a Slack destination.

The internal form-page webhook uses the private edge-to-n8n SSO credential. The browser submits only the natural-language question, and report output is rendered with DOM textContent.

## Safe default

/sso/form returns 404 while SSO_ENABLED=false. Enable it only with a real client domain, trusted TLS certificate, and configured OIDC provider.

## Deploy and verify

bash scripts/deploy-manager-form.sh --confirm REVINT_MANAGER_FORM
bash scripts/verify-manager-form.sh
