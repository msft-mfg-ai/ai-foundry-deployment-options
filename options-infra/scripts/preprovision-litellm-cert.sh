#!/usr/bin/env sh
# preprovision-litellm-cert.sh
# ---------------------------------------------------------------------------
# Generates a self-signed root CA + leaf certificate for the LiteLLM container
# app, then writes the cert material into the azd environment so main.bicepparam
# can read them via `readEnvironmentVariable`.
#
# Contract:
#   inputs  : env LITELLM_DOMAIN  (FQDN the leaf cert covers, e.g. litellm.contoso.internal)
#             env AZURE_ENV_NAME  (set by azd; only used for the CA CN)
#   outputs : azd env vars
#               LITELLM_CERT_PFX_BASE64       — leaf PFX (cert + key + CA chain)
#               LITELLM_CERT_PFX_PASSWORD     — PFX password
#               LITELLM_ROOT_CA_PEM_BASE64    — root CA cert in PEM (no key)
#
#             The PFX is bound to the ACA managed environment as a certificate
#             resource and presented at the ACA ingress for the custom
#             domain — ACA terminates TLS, so the LiteLLM container itself
#             does NOT consume the cert. The root CA is installed in the
#             nginx proxy so it can validate ACA's leaf cert.
#
# Idempotency:
#     If all three output env vars are already non-empty in the azd env, the
#   script exits without regenerating. Set FORCE_REGENERATE=1 to override.
# ---------------------------------------------------------------------------
set -eu

if [ -z "${LITELLM_DOMAIN:-}" ]; then
  echo "⚠ LITELLM_DOMAIN is not set — skipping cert generation."
  echo "  This is expected during the first (DNS-validation) phase. After"
  echo "  configuring DNS, run 'azd env set LITELLM_DOMAIN <fqdn>' and re-run"
  echo "  'azd provision'."
  exit 0
fi

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "AZURE_ENV_NAME is not set; aborting." >&2
  exit 1
fi

# Idempotency check
existing_pfx=$(azd env get-value LITELLM_CERT_PFX_BASE64 2>/dev/null || true)
existing_pwd=$(azd env get-value LITELLM_CERT_PFX_PASSWORD 2>/dev/null || true)
existing_ca=$(azd env get-value LITELLM_ROOT_CA_PEM_BASE64 2>/dev/null || true)

if [ -z "${FORCE_REGENERATE:-}" ] \
   && [ -n "$existing_pfx" ] && [ -n "$existing_pwd" ] && [ -n "$existing_ca" ]; then
  echo "→ LiteLLM cert material already present in azd env; skipping regeneration."
  echo "  (set FORCE_REGENERATE=1 to force a new cert)"
  exit 0
fi

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required but not installed; aborting." >&2
  exit 1
}

echo "→ Generating self-signed cert for '${LITELLM_DOMAIN}'..."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ca_key="$work/rootCA.key"
ca_crt="$work/rootCA.crt"
leaf_key="$work/leaf.key"
leaf_csr="$work/leaf.csr"
leaf_crt="$work/leaf.crt"
leaf_chain="$work/leaf-chain.pem"
leaf_pfx="$work/leaf.pfx"
ext_file="$work/leaf.ext"

# Root CA (10 years, 4096-bit)
openssl genrsa -out "$ca_key" 4096 >/dev/null 2>&1
openssl req -x509 -new -nodes -key "$ca_key" -sha256 -days 3650 \
  -subj "/CN=LiteLLM Dev Root CA ${AZURE_ENV_NAME}/O=ai-foundry-config-testing" \
  -out "$ca_crt" >/dev/null 2>&1

# Leaf key + CSR
openssl genrsa -out "$leaf_key" 2048 >/dev/null 2>&1
openssl req -new -key "$leaf_key" \
  -subj "/CN=${LITELLM_DOMAIN}/O=ai-foundry-config-testing" \
  -out "$leaf_csr" >/dev/null 2>&1

# v3 SAN extensions — required by modern TLS clients
cat > "$ext_file" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${LITELLM_DOMAIN}
EOF

openssl x509 -req -in "$leaf_csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial \
  -out "$leaf_crt" -days 825 -sha256 -extfile "$ext_file" >/dev/null 2>&1

# Build chain (leaf + CA) for tools that expect a single PEM bundle
cat "$leaf_crt" "$ca_crt" > "$leaf_chain"

# PFX with random password
pfx_password=$(openssl rand -base64 24)
openssl pkcs12 -export \
  -inkey "$leaf_key" -in "$leaf_crt" -certfile "$ca_crt" \
  -password "pass:${pfx_password}" \
  -out "$leaf_pfx" >/dev/null 2>&1

# openssl base64 -A → single-line, no trailing newline
b64_pfx=$(openssl base64 -A -in "$leaf_pfx")
b64_ca=$(openssl base64 -A -in "$ca_crt")

azd env set LITELLM_CERT_PFX_BASE64 "$b64_pfx"
azd env set LITELLM_CERT_PFX_PASSWORD "$pfx_password"
azd env set LITELLM_ROOT_CA_PEM_BASE64 "$b64_ca"

echo "✓ Self-signed cert generated and stored in azd env (3 vars)."
echo "  Leaf CN/SAN : ${LITELLM_DOMAIN}"
echo "  Root CA CN  : LiteLLM Dev Root CA ${AZURE_ENV_NAME}"
