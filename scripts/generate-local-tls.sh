#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS_DIR="${TLS_DIR:-$ROOT_DIR/deploy/tls}"
DOMAIN="${PUBLIC_DOMAIN:-localhost}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v openssl >/dev/null || fail "openssl is not available."
mkdir -p "$TLS_DIR"
chmod 700 "$TLS_DIR"

cert="$TLS_DIR/tls.crt"
key="$TLS_DIR/tls.key"

openssl req   -x509   -newkey rsa:2048   -sha256   -nodes   -days 7   -keyout "$key"   -out "$cert"   -subj "/CN=$DOMAIN"   -addext "subjectAltName=DNS:$DOMAIN,IP:127.0.0.1"   >/dev/null 2>&1

chmod 600 "$key"
chmod 600 "$cert"

openssl x509 -in "$cert" -noout -checkend 60 >/dev/null
openssl pkey -in "$key" -noout >/dev/null

cert_pub="$(openssl x509 -in "$cert" -pubkey -noout | sha256sum | awk '{print $1}')"
key_pub="$(openssl pkey -in "$key" -pubout | sha256sum | awk '{print $1}')"
[[ "$cert_pub" == "$key_pub" ]] || fail "generated certificate and private key do not match."

echo "PASS: local TLS certificate generated."
echo "TLS_CERT=$cert"
echo "TLS_KEY=$key"
echo "NOTE: This certificate is for local verification only and is not publicly trusted."
