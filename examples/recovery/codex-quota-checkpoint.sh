#!/bin/sh
set -eu

# A provider hook adapter must project these structured values.
# Raw notify JSON, errors, prompts, and output are never forwarded to LimitBar.
: "${LIMITBAR_SESSION_REFERENCE:?opaque Codex session reference is required}"
: "${LIMITBAR_RESET_BOUNDARY:?provider-reported ISO 8601 reset boundary is required}"
: "${CODEX_VERSION:?Codex version is required}"
: "${LIMITBAR_QUOTA_WINDOW_KIND:?session or weekly is required}"
case "$LIMITBAR_QUOTA_WINDOW_KIND" in
  session|weekly) ;;
  *) exit 64 ;;
esac

LIMITBAR_CLI=${LIMITBAR_CLI:-limitbar}
WORKSPACE=${LIMITBAR_WORKSPACE:-$PWD}
FINGERPRINT=$("$LIMITBAR_CLI" recovery fingerprint --workspace "$WORKSPACE")
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -cn \
  --arg product "codex" \
  --arg session_reference "$LIMITBAR_SESSION_REFERENCE" \
  --arg workspace_fingerprint "$FINGERPRINT" \
  --arg client_version "$CODEX_VERSION" \
  --arg failure_class "quota_exhausted" \
  --arg window_kind "$LIMITBAR_QUOTA_WINDOW_KIND" \
  --arg reset_boundary "$LIMITBAR_RESET_BOUNDARY" \
  --arg created_at "$CREATED_AT" \
  '{schema_version:2,product:$product,session_reference:$session_reference,workspace_fingerprint:$workspace_fingerprint,client_version:$client_version,failure_class:$failure_class,window_kind:$window_kind,reset_boundary:$reset_boundary,created_at:$created_at}' \
  | "$LIMITBAR_CLI" recovery import
