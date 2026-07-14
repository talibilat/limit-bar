#!/bin/bash
set -euo pipefail

required=(
  RELEASE_TAG
  DEVELOPER_ID_APPLICATION
  DEVELOPER_ID_P12_BASE64
  DEVELOPER_ID_P12_PASSWORD
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_PASSWORD
)
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    printf 'error: required protected release value %s is missing\n' "$name" >&2
    exit 1
  fi
done

if [[ ! "$RELEASE_TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  printf 'error: RELEASE_TAG must use vMAJOR.MINOR.PATCH\n' >&2
  exit 1
fi
if [[ -z "$(git tag --points-at HEAD --list "$RELEASE_TAG")" ]]; then
  printf 'error: checked-out commit is not tagged %s\n' "$RELEASE_TAG" >&2
  exit 1
fi
if [[ "$(git cat-file -t "refs/tags/$RELEASE_TAG")" != "tag" ]]; then
  printf 'error: RELEASE_TAG must be an annotated tag\n' >&2
  exit 1
fi
if ! git merge-base --is-ancestor HEAD origin/main; then
  printf 'error: tagged release commit must be reachable from origin/main\n' >&2
  exit 1
fi
if [[ "$DEVELOPER_ID_APPLICATION" != Developer\ ID\ Application:*"($APPLE_TEAM_ID)" ]]; then
  printf 'error: signing identity must be a Developer ID Application identity for APPLE_TEAM_ID\n' >&2
  exit 1
fi

printf 'release preflight accepted tag and protected environment values\n'
