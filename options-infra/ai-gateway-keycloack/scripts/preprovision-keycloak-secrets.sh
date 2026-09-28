#!/usr/bin/env sh
set -eu

ensure_secret() {
  name=$1
  value=$(azd env get-value "$name" 2>/dev/null) || value=''
  if [ -z "$value" ]; then
    value=$(openssl rand -hex 32)
    azd env set "$name" "$value" >/dev/null
    printf 'Generated %s for this azd environment.\n' "$name"
  else
    printf 'Reusing existing %s from this azd environment.\n' "$name"
  fi
}

command -v openssl >/dev/null 2>&1 || {
  printf 'openssl is required to generate Keycloak secrets.\n' >&2
  exit 1
}

ensure_secret KEYCLOAK_ADMIN_PASSWORD
ensure_secret KEYCLOAK_CLIENT_SECRET
