#!/bin/bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
exec ruby "$root/scripts/scan-prohibited-content.rb" "$@"
