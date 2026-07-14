#!/bin/bash

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
manifest="$root/LimitBarCore/Tests/LimitBarCoreTests/Fixtures/Migrations/manifest.json"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

DEVELOPER_DIR="$developer_dir" swift run --package-path "$root/LimitBarCore" -c release limitbar-migration-validator "$manifest"
