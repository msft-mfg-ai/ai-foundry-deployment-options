#!/bin/bash
# Generate .env file from azd deployment outputs.
# Run after `azd provision` or `azd up` to create a .env that the test notebook can load.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

echo "# Generated from azd env on $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ENV_FILE"
echo "# Re-run scripts/generate-env.sh to refresh" >> "$ENV_FILE"
echo "" >> "$ENV_FILE"

azd env get-values >> "$ENV_FILE"

echo "✅ Generated $ENV_FILE ($(grep -c '=' "$ENV_FILE") variables)"
