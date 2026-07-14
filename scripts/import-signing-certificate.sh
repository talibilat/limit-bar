#!/bin/bash
set -euo pipefail

: "${DEVELOPER_ID_P12_BASE64:?missing protected certificate}"
: "${DEVELOPER_ID_P12_PASSWORD:?missing protected certificate password}"
: "${GITHUB_ENV:?missing GitHub environment file}"

keychain="$RUNNER_TEMP/limitbar-signing.keychain-db"
certificate="$RUNNER_TEMP/limitbar-signing.p12"
keychain_password="$(openssl rand -hex 32)"
trap 'rm -f "$certificate" "$keychain"' EXIT

printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -D > "$certificate"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain"
security list-keychains -d user -s "$keychain" login.keychain-db
printf 'LIMITBAR_SIGNING_KEYCHAIN=%s\n' "$keychain" >> "$GITHUB_ENV"

# The job needs the keychain after this script exits, but never the exported certificate.
trap - EXIT
rm -f "$certificate"
printf 'signing certificate imported into an ephemeral keychain\n'
