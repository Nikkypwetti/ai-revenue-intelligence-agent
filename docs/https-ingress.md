# Agent v2 — HTTPS & Public Ingress

## Status

Locally verified on the isolated Agent v2 deployment.

The ingress layer is public-capable but intentionally binds to loopback by default. Public internet activation remains an explicit deployment action requiring a real domain, a trusted certificate, the correct public webhook URL, firewall/NAT configuration, and a confirmation token.

## Architecture

```text
Internet / client
      |
      | HTTPS
      v
nginx ingress
  - TLS termination
  - exact route allowlist
  - method enforcement
  - security headers
      |
      | private Docker network
      v
Agent v2 n8n :5678
```

The n8n backend remains published only on host loopback port `5681`. The protected older local n8n instance remains separate on `5678`.

The ingress service connects to:

- `ingress_public` — the Docker network used for host/public port publishing
- `agent_private` — the internal network used to reach the Agent v2 n8n backend

The n8n service is **not** attached to `ingress_public`.

## Exposed routes

Only these Agent v2 routes are proxied:

- `POST /webhook/revint/v2/deals`
- `POST /webhook/revint/v2/report`

Both routes already enforce n8n Header Auth credentials.

The ingress also provides its own lightweight:

- `GET /healthz`

All other paths return `404`. In particular, the n8n editor, sign-in page, REST administration surface, and unrelated webhooks are not exposed through this ingress.

## TLS policy

nginx is configured for:

- TLS 1.2
- TLS 1.3
- TLS session tickets disabled
- server version tokens disabled
- 128 KiB request-body limit
- `X-Content-Type-Options: nosniff`
- `Referrer-Policy: no-referrer`
- `X-Frame-Options: DENY`
- `Cache-Control: no-store`

HTTP requests are redirected to the configured HTTPS origin.

## Trusted proxy boundary

The n8n container receives:

```text
N8N_PROXY_HOPS=1
```

The nginx proxy supplies the forwarded host, protocol, port, client IP, and forwarding-chain headers.

This trust depth matches the deployment architecture: exactly one controlled reverse proxy exists between the external caller and Agent v2 n8n.

## Local verification

Generate a short-lived local certificate:

```bash
bash scripts/generate-local-tls.sh
```

The generated certificate and key are stored under `deploy/tls/`, are ignored by Git, and are intended only for local verification.

Deploy the local ingress:

```bash
bash scripts/deploy-https-ingress.sh
```

Default local bindings:

```text
HTTP  -> 127.0.0.1:8080
HTTPS -> 127.0.0.1:8443
```

Run acceptance tests:

```bash
bash scripts/verify-https-ingress.sh
```

## Public activation

Before public activation:

1. Point a real DNS name to the deployment host.
2. Obtain a certificate and private key from a trusted CA.
3. Store them locally as:
   - `deploy/tls/tls.crt`
   - `deploy/tls/tls.key`
4. Protect the private key with owner-only permissions.
5. Set:
   - `PUBLIC_DOMAIN=<your-domain>`
   - `PUBLIC_HTTPS_ORIGIN=https://<your-domain>`
   - `INGRESS_BIND_ADDRESS=0.0.0.0`
   - `INGRESS_HTTP_PORT=80`
   - `INGRESS_HTTPS_PORT=443`
   - `N8N_WEBHOOK_URL=https://<your-domain>/`
6. Ensure the host/network firewall exposes only the intended edge ports.
7. Keep Agent v2 port `5681` bound to loopback.
8. Run:

```bash
bash scripts/deploy-https-ingress.sh \
  --confirm-public REVINT_PUBLIC_HTTPS_INGRESS
```

A non-loopback bind fails closed without that confirmation token.

## Certificate handling

The repository never contains production certificate or private-key material.

The local generator produces a seven-day self-signed certificate only for verification. Production certificate issuance and renewal should be managed by the deployment platform or a trusted ACME/certificate process.

## Authentication boundary

This milestone does **not** make the n8n editor public. Only the two existing Header Auth API/webhook routes are exposed.

External SSO/identity-provider integration for an administrative or manager-facing web UI remains a separate production-foundation milestone.
