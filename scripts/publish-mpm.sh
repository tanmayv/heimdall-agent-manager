#!/usr/bin/env bash
# Build and publish Heimdall Cloudtop MPM package
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PKGDEF="packaging/mpm/heimdall.pkgdef"
BUNDLE_DIR="dist/heimdall-cloudtop"

if [ ! -d "$BUNDLE_DIR" ] || [ ! -f "$BUNDLE_DIR/bin/ham-hub" ] || [ ! -f "$BUNDLE_DIR/ui/index.html" ]; then
  echo "[mpm] Standalone bundle missing or incomplete. Building package bundle first..."
  "$ROOT/scripts/package-cloudtop-bundle.sh"
fi

if ! command -v mpm >/dev/null 2>&1; then
  echo "[-] mpm command not found on PATH. Ensure Google internal tools are available."
  exit 1
fi

BRANCH="${1:-dev}"
if [[ "$BRANCH" != -* ]]; then
  shift || true
  EXTRA_ARGS=("-b" "$BRANCH" "$@")
else
  EXTRA_ARGS=("$@")
fi

echo "[mpm] Building and publishing package 'heimdall/cloudtop'..."
echo "[mpm] Command: mpm build -f $PKGDEF ${EXTRA_ARGS[*]}"
mpm build -f "$PKGDEF" "${EXTRA_ARGS[@]}"

echo ""
echo "=== MPM Package Published Successfully ==="
echo "Install on any Cloudtop machine via:"
echo "  mpm install heimdall/cloudtop live ~/.local/share/heimdall"
echo "  ~/.local/share/heimdall/bin/start.sh"
