#!/usr/bin/env bash
# T8 / REQ-SIGN-1: notarize the standalone macOS binaries.
#
# Usage: notarize-macos-binaries.sh <heimdall-local-darwin-*.tar.gz>
# Env:   APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID (required)
#        NOTARYTOOL (optional override of "xcrun notarytool", for tests)
#
# The tarball's Mach-O files are already Developer ID-signed with hardened
# runtime and a secure timestamp (package-local-binary-tarball.sh). A bare
# binary cannot hold a stapled ticket, so this submits a zip of bin/ and
# relies on Gatekeeper's online ticket lookup. The tarball bytes, and so its
# SHA-256, are NOT changed. Fails unless Apple reports status Accepted, and
# prints the notary log on any other outcome.
set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || { echo "usage: $0 <heimdall-local-darwin-*.tar.gz>" >&2; exit 2; }
tarball="$1"
[ -f "$tarball" ] || die "$tarball does not exist"
for v in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
  [ -n "${!v:-}" ] || die "$v is required for notarization"
done

if [ -n "${NOTARYTOOL:-}" ]; then
  notary=("$NOTARYTOOL")
else
  notary=(xcrun notarytool)
fi
auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$tarball" -C "$work"
[ -d "$work/bin" ] || die "$tarball has no bin/ directory"

zip="$work/heimdall-local-bin.zip"
if command -v ditto >/dev/null 2>&1; then
  ditto -c -k --keepParent "$work/bin" "$zip"
else
  (cd "$work" && zip -qr "$zip" bin)
fi

json_field() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

echo "Submitting $(basename "$tarball") binaries for notarization"
# notarytool's exit code differs across Xcode versions for an Invalid
# submission, so the JSON status decides; a non-JSON reply is a failure.
rc=0
result="$("${notary[@]}" submit "$zip" "${auth[@]}" --wait --output-format json)" || rc=$?
id="$(printf '%s' "$result" | json_field id 2>/dev/null || true)"
status="$(printf '%s' "$result" | json_field status 2>/dev/null || true)"
echo "notarization id=${id:-unknown} status=${status:-unknown} exit=$rc"
[ -n "$status" ] || { echo "$result" >&2; die "notarytool submit returned no status"; }

if [ "$status" != "Accepted" ]; then
  if [ -n "$id" ]; then
    "${notary[@]}" log "$id" "${auth[@]}" >&2 || true
  fi
  die "notarization status is '${status:-unknown}', expected Accepted"
fi
