#!/usr/bin/env bash
# Installer smoke test for the thin bootstrap (scripts/install.sh).
#
# Always: syntax check plus the hermetic bootstrap tests (mock curl, stub
# ham-bridge; nothing is installed). With INSTALL_SMOKE_HUB=<url> it also runs the
# REAL `curl | bash` path on this host from the newest promoted release (or
# INSTALL_SMOKE_VERSION) in a throwaway HOME, then `ham-bridge status --json` and
# `ham-bridge uninstall --purge`. The real run registers a user service, so it is
# meant for CI runners and disposable VMs; enrollment needs an approver, so pass a
# Hub that auto-approves or expect the run to wait at the enroll step.
#
# With HEIMDALL_E2E_HUB_BIN, HEIMDALL_E2E_BRIDGE_BIN (and HEIMDALL_E2E_NATS_BIN) it
# runs the REQ-INSTALL-2 scenarios (tests/e2e/installer_scenarios_e2e.mjs): the real
# install.sh with a bundle of those binaries against a throwaway local hub (fresh
# install, no-op re-run, re-enroll after the credential is removed and after a
# revoke, recovery from an interrupted install, uninstall), all without a TTY. It
# registers a real user service under a random profile name; needs `npm ci`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bash -n "$ROOT/scripts/install.sh"
python3 "$ROOT/tests/test_installer_clean.py"
if [ -n "${HEIMDALL_E2E_HUB_BIN:-}" ] && [ -n "${HEIMDALL_E2E_BRIDGE_BIN:-}" ]; then
  (cd "$ROOT" && node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/installer_scenarios_e2e.mjs)
fi
[ -n "${INSTALL_SMOKE_HUB:-}" ] || { echo 'installer-smoke: hermetic checks passed (set INSTALL_SMOKE_HUB for the real install)'; exit 0; }

home="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-smoke-home.XXXXXX")"
trap 'rm -rf "$home"' EXIT
export HOME="$home"
args=(--hub "$INSTALL_SMOKE_HUB")
[ -z "${INSTALL_SMOKE_VERSION:-}" ] || args+=(--version "$INSTALL_SMOKE_VERSION")
bash "$ROOT/scripts/install.sh" "${args[@]}"
bridge="$(find "$HOME" -path '*/heimdall/bridges/*/bin/ham-bridge' -type f | head -n 1)"
[ -n "$bridge" ] || { echo 'installer-smoke: no installed ham-bridge found' >&2; exit 1; }
"$bridge" status --json
"$bridge" uninstall --hub "$INSTALL_SMOKE_HUB" --purge --yes
echo 'installer-smoke: install, status and uninstall --purge passed'
