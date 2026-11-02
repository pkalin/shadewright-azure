#!/usr/bin/env bash
# Checks the GitHub App setup end to end, the same way the executor will (ADR-0006):
# builds an App JWT, signs it with the non-exportable key in Key Vault, and asks GitHub who the App is and where
# it is installed. Prints no token or key material.
#
# Usage: scripts/github-app-check.sh <key-vault-name> <app-client-id-or-app-id> [key-name]
set -euo pipefail

vault=${1:?key vault name}
issuer=${2:?GitHub App client ID (Iv23...) or numeric app ID}
key=${3:-github-app}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$issuer" | b64url)
digest=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -binary | openssl base64 -A)

sig=$(az keyvault key sign --vault-name "$vault" --name "$key" --algorithm RS256 --digest "$digest" --query signature -o tsv)
jwt="$header.$payload.$(printf '%s' "$sig" | tr '+/' '-_' | tr -d '=')"

gh_api() { curl -fsS -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com$1"; }

echo "App:"
gh_api /app | jq -r '"  \(.name) (id \(.id), slug \(.slug))\n  permissions: \(.permissions|to_entries|map("\(.key)=\(.value)")|join(", "))\n  events: \(.events|join(", ") // "")"'
echo "Installations:"
gh_api /app/installations | jq -r '.[] | "  id \(.id) on \(.account.login), repositories: \(.repository_selection)"'

echo "Key in Key Vault:"
az keyvault key show --vault-name "$vault" --name "$key" \
  --query '{type:key.kty, ops:key.keyOps, exportable:attributes.exportable}' -o json | jq -c .
