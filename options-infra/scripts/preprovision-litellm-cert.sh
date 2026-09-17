#!/usr/bin/env sh
# Generates independent private CAs and leaf certificates for the LiteLLM and
# optional MCP custom domains. The public roots are also concatenated into one
# PEM bundle for inspection/export; Foundry receives one Key Vault secret
# reference per root because it loads only one PEM certificate from each entry.
set -eu

if [ -z "${LITELLM_DOMAIN:-}" ]; then
  echo "⚠ LITELLM_DOMAIN is not set — skipping cert generation."
  echo "  This is expected during phase 1. Configure DNS, set LITELLM_DOMAIN,"
  echo "  optionally set MCP_DOMAIN, and rerun 'azd provision'."
  exit 0
fi

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "AZURE_ENV_NAME is not set; aborting." >&2
  exit 1
fi

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required but not installed; aborting." >&2
  exit 1
}

get_azd_value() {
  value=$(azd env get-value "$1" 2>/dev/null) || value=""
  printf '%s' "$value"
}

existing_pfx=$(get_azd_value LITELLM_CERT_PFX_BASE64)
existing_pwd=$(get_azd_value LITELLM_CERT_PFX_PASSWORD)
existing_ca=$(get_azd_value LITELLM_ROOT_CA_PEM_BASE64)
existing_mcp_pfx=$(get_azd_value MCP_CERT_PFX_BASE64)
existing_mcp_pwd=$(get_azd_value MCP_CERT_PFX_PASSWORD)
existing_mcp_ca=$(get_azd_value MCP_ROOT_CA_PEM_BASE64)
existing_bundle=$(get_azd_value FOUNDRY_TRUSTED_CA_BUNDLE_PEM_BASE64)

if [ -z "${FORCE_REGENERATE:-}" ] \
   && [ -z "${FORCE_REGENERATE_MCP:-}" ] \
   && [ -n "$existing_pfx" ] && [ -n "$existing_pwd" ] && [ -n "$existing_ca" ] \
   && { [ -z "${MCP_DOMAIN:-}" ] || { [ -n "$existing_mcp_pfx" ] && [ -n "$existing_mcp_pwd" ] && [ -n "$existing_mcp_ca" ] && [ -n "$existing_bundle" ]; }; }; then
  echo "→ Certificate material already present in azd env; skipping regeneration."
  echo "  Set FORCE_REGENERATE=1 for all certs or FORCE_REGENERATE_MCP=1 for MCP only."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

generate_pair() {
  prefix=$1
  domain=$2
  ca_common_name=$3
  ca_key="$work/${prefix}-root.key"
  ca_crt="$work/${prefix}-root.crt"
  leaf_key="$work/${prefix}-leaf.key"
  leaf_csr="$work/${prefix}-leaf.csr"
  leaf_crt="$work/${prefix}-leaf.crt"
  leaf_pfx="$work/${prefix}-leaf.pfx"
  ext_file="$work/${prefix}-leaf.ext"

  openssl genrsa -out "$ca_key" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "$ca_key" -sha256 -days 3650 \
    -subj "/CN=${ca_common_name}/O=ai-foundry-config-testing" \
    -out "$ca_crt" >/dev/null 2>&1

  openssl genrsa -out "$leaf_key" 2048 >/dev/null 2>&1
  openssl req -new -key "$leaf_key" \
    -subj "/CN=${domain}/O=ai-foundry-config-testing" \
    -out "$leaf_csr" >/dev/null 2>&1

  cat > "$ext_file" <<EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${domain}
EOF

  openssl x509 -req -in "$leaf_csr" -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial \
    -out "$leaf_crt" -days 825 -sha256 -extfile "$ext_file" >/dev/null 2>&1

  generated_password=$(openssl rand -base64 24)
  openssl pkcs12 -export \
    -inkey "$leaf_key" -in "$leaf_crt" -certfile "$ca_crt" \
    -passout "pass:${generated_password}" -out "$leaf_pfx" >/dev/null 2>&1

  generated_pfx=$(openssl base64 -A -in "$leaf_pfx")
  generated_ca=$(openssl base64 -A -in "$ca_crt")
}

lite_root_file="$work/litellm-root.pem"
if [ -n "${FORCE_REGENERATE:-}" ] || [ -z "$existing_pfx" ] || [ -z "$existing_pwd" ] || [ -z "$existing_ca" ]; then
  echo "→ Generating private CA and leaf certificate for '${LITELLM_DOMAIN}'..."
  generate_pair "litellm" "$LITELLM_DOMAIN" "LiteLLM Dev Root CA ${AZURE_ENV_NAME}"
  existing_pfx=$generated_pfx
  existing_pwd=$generated_password
  existing_ca=$generated_ca
  azd env set LITELLM_CERT_PFX_BASE64 "$existing_pfx"
  azd env set LITELLM_CERT_PFX_PASSWORD "$existing_pwd"
  azd env set LITELLM_ROOT_CA_PEM_BASE64 "$existing_ca"
fi
printf '%s' "$existing_ca" | openssl base64 -d -A > "$lite_root_file"

bundle_file="$work/foundry-trusted-ca-bundle.pem"
cat "$lite_root_file" > "$bundle_file"
printf '\n' >> "$bundle_file"

if [ -n "${MCP_DOMAIN:-}" ]; then
  mcp_root_file="$work/mcp-root.pem"
  if [ -n "${FORCE_REGENERATE:-}" ] || [ -n "${FORCE_REGENERATE_MCP:-}" ] \
     || [ -z "$existing_mcp_pfx" ] || [ -z "$existing_mcp_pwd" ] || [ -z "$existing_mcp_ca" ]; then
    echo "→ Generating independent private CA and leaf certificate for '${MCP_DOMAIN}'..."
    generate_pair "mcp" "$MCP_DOMAIN" "MCP Dev Root CA ${AZURE_ENV_NAME}"
    existing_mcp_pfx=$generated_pfx
    existing_mcp_pwd=$generated_password
    existing_mcp_ca=$generated_ca
    azd env set MCP_CERT_PFX_BASE64 "$existing_mcp_pfx"
    azd env set MCP_CERT_PFX_PASSWORD "$existing_mcp_pwd"
    azd env set MCP_ROOT_CA_PEM_BASE64 "$existing_mcp_ca"
  fi
  printf '%s' "$existing_mcp_ca" | openssl base64 -d -A > "$mcp_root_file"
  cat "$mcp_root_file" >> "$bundle_file"
  printf '\n' >> "$bundle_file"
fi

bundle_base64=$(openssl base64 -A -in "$bundle_file")
azd env set FOUNDRY_TRUSTED_CA_BUNDLE_PEM_BASE64 "$bundle_base64"

echo "✓ Certificate material prepared for ACA and Foundry private CA trust."
echo "  LiteLLM leaf : ${LITELLM_DOMAIN}"
if [ -n "${MCP_DOMAIN:-}" ]; then
  echo "  MCP leaf     : ${MCP_DOMAIN}"
  echo "  CA bundle    : LiteLLM root + MCP root"
else
  echo "  CA bundle    : LiteLLM root"
fi
