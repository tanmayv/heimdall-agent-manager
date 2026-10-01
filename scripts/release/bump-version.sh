#!/usr/bin/env bash
# scripts/release/bump-version.sh
# Synchronizes application version, git commit, and build timestamp
# across package.json, flake.nix, and src/contracts/protocol.odin (REQ-REL-VER-SYNC-1).
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: bump-version.sh <version> [commit_sha] [build_timestamp]

Arguments:
  <version>          Semver version string (e.g. "0.3.3" or "v0.3.3")
  [commit_sha]       Optional git commit short SHA (default: git rev-parse --short HEAD)
  [build_timestamp]  Optional ISO 8601 UTC timestamp (default: current UTC time)

Examples:
  ./scripts/release/bump-version.sh 0.3.3
  ./scripts/release/bump-version.sh v0.3.3 abcdef12 2026-10-01T12:00:00Z
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "$#" -lt 1 ]; then
  usage
  exit 0
fi

RAW_VERSION="$1"
CLEAN_VERSION="${RAW_VERSION#v}"

# Validate semantic version syntax (e.g. 0.3.3, 0.3.3-beta.1)
if ! [[ "$CLEAN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "ERROR: Invalid semantic version format: '$RAW_VERSION'" >&2
  exit 1
fi

COMMIT_SHA="${2:-}"
if [ -z "$COMMIT_SHA" ]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    COMMIT_SHA="$(git rev-parse --short=8 HEAD 2>/dev/null || true)"
  fi
fi

TIMESTAMP="${3:-$(date -u +'%Y-%m-%dT%H:%M:%SZ')}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

echo "==> Stamping version across Heimdall project files:"
echo "    Version:         $CLEAN_VERSION (tag: v$CLEAN_VERSION)"
echo "    Commit SHA:      ${COMMIT_SHA:-'(none)'}"
echo "    Build Timestamp: $TIMESTAMP"

# 1. Update flake.nix appVersion
if [ -f "flake.nix" ]; then
  sed -i "s/appVersion = \".*\";/appVersion = \"$CLEAN_VERSION\";/" flake.nix
  echo "    [ok] Updated flake.nix (appVersion = \"$CLEAN_VERSION\")"
fi

# 2. Update src/contracts/protocol.odin defaults
if [ -f "src/contracts/protocol.odin" ]; then
  sed -i "s/APP_VERSION :: #config(HAM_APP_VERSION, \".*\")/APP_VERSION :: #config(HAM_APP_VERSION, \"$CLEAN_VERSION\")/" src/contracts/protocol.odin
  if [ -n "$COMMIT_SHA" ]; then
    sed -i "s/GIT_COMMIT :: #config(HAM_GIT_COMMIT, \".*\")/GIT_COMMIT :: #config(HAM_GIT_COMMIT, \"$COMMIT_SHA\")/" src/contracts/protocol.odin
  fi
  sed -i "s/BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, \".*\")/BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, \"$TIMESTAMP\")/" src/contracts/protocol.odin
  echo "    [ok] Updated src/contracts/protocol.odin"
fi

# 3. Update package.json
if [ -f "package.json" ]; then
  if command -v npm >/dev/null 2>&1; then
    npm version "$CLEAN_VERSION" --no-git-tag-version --allow-same-version >/dev/null 2>&1 || true
  else
    sed -i "s/\"version\": \".*\"/\"version\": \"$CLEAN_VERSION\"/" package.json
  fi
  echo "    [ok] Updated package.json (\"version\": \"$CLEAN_VERSION\")"
fi

echo "==> Version synchronization complete."
