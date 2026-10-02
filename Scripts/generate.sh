#!/usr/bin/env bash
# Generate KVoice.xcodeproj from project.yml (the project is not committed).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "install xcodegen: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
