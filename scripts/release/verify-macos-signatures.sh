#!/usr/bin/env bash
# REQ-SIGN-1 / T8: verify the signatures on the standalone macOS binaries.
#
# Usage: verify-macos-signatures.sh <heimdall-local-darwin-*.tar.gz | bin-dir>
#
# The curl installer, the DMG and Bridge self-update all install these bare
# Mach-O files. A bare binary cannot carry a stapled notarization ticket, so
# what Gatekeeper and the Keychain rely on is the signature itself. Every
# Mach-O file under bin/ must have:
#   - a valid, strict signature (codesign --verify --strict)
#   - a Developer ID Application leaf chaining to Apple Root CA
#   - the hardened runtime flag (flags=...(runtime))
#   - a secure timestamp (Timestamp=, not a local "Signed Time=")
#   - the stable identifier package-local-binary-tarball.sh assigns
#   - one TeamIdentifier shared by all binaries (equal to
#     HEIMDALL_EXPECTED_TEAM_ID when that is set)
#   - no com.apple.security.get-task-allow entitlement (debug-only)
#   - with HEIMDALL_REQUIRE_NOTARIZED=1: a notarization ticket Apple serves
#     online (codesign --check-notarization, requirement "=notarized")
# ham-bridge and ham-ctl are required; ham-pty-host is checked when present.
#
# Release CI runs this on the build runner and again on a clean runner that
# never imported the signing keychain. CODESIGN overrides the codesign binary
# so tests can drive the checks on any OS.
set -euo pipefail

codesign_bin="${CODESIGN:-codesign}"
expected_team="${HEIMDALL_EXPECTED_TEAM_ID:-}"
require_notarized="${HEIMDALL_REQUIRE_NOTARIZED:-0}"

die() { echo "FAIL: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || { echo "usage: $0 <heimdall-local-darwin-*.tar.gz | bin-dir>" >&2; exit 2; }
input="$1"

if [ -d "$input" ]; then
  bin_dir="$input"
elif [ -f "$input" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  tar -xzf "$input" -C "$work"
  bin_dir="$work/bin"
  [ -d "$bin_dir" ] || die "$input has no bin/ directory"
else
  die "$input does not exist"
fi

command -v "$codesign_bin" >/dev/null 2>&1 || die "codesign not found ($codesign_bin)"

# Keep in step with package-local-binary-tarball.sh (REQ-SIGN-1 block).
expected_identifier() {
  case "$1" in
    ham-bridge) echo works.earendil.heimdall.bridge ;;
    ham-ctl) echo works.earendil.heimdall.ctl ;;
    ham-pty-host) echo works.earendil.heimdall.pty-host ;;
    ham-launcher) echo works.earendil.heimdall.launcher ;;
    ham-supervisor) echo works.earendil.heimdall.supervisor ;;
    *) echo "works.earendil.heimdall.$(printf '%s' "$1" | tr -cs 'A-Za-z0-9.-' '-')" ;;
  esac
}

is_macho() {
  case "$(od -A n -t x1 -N 4 "$1" 2>/dev/null | tr -d ' \n')" in
    cffaedfe|cefaedfe|cafebabe|cafebabf|feedface|feedfacf) return 0 ;;
  esac
  return 1
}

for required in ham-bridge ham-ctl; do
  [ -f "$bin_dir/$required" ] || die "$required is missing from $bin_dir"
done

team=""
checked=0
for f in "$bin_dir"/*; do
  [ -f "$f" ] || continue
  is_macho "$f" || continue
  name="$(basename "$f")"

  "$codesign_bin" --verify --strict --verbose=2 "$f" || die "$name: signature does not verify"

  details="$("$codesign_bin" -d --verbose=4 "$f" 2>&1)" || die "$name: codesign -d failed: $details"

  authorities="$(printf '%s\n' "$details" | sed -n 's/^Authority=//p')"
  printf '%s\n' "$authorities" | head -n 1 | grep -q '^Developer ID Application: ' \
    || die "$name: leaf authority is not Developer ID Application"
  printf '%s\n' "$authorities" | grep -qx 'Developer ID Certification Authority' \
    || die "$name: chain lacks Developer ID Certification Authority"
  printf '%s\n' "$authorities" | grep -qx 'Apple Root CA' \
    || die "$name: chain lacks Apple Root CA"

  # CodeDirectory v=20500 size=... flags=0x10000(runtime) hashes=...
  flags="$(printf '%s\n' "$details" | sed -n 's/^CodeDirectory .*flags=\(0x[0-9a-fA-F]*([^)]*)\).*/\1/p' | head -n 1)"
  case "$flags" in
    *runtime*) ;;
    *) die "$name: hardened runtime is not enabled (flags=${flags:-none})" ;;
  esac

  printf '%s\n' "$details" | grep -q '^Timestamp=' \
    || die "$name: no secure timestamp (signed without --timestamp)"

  identifier="$(printf '%s\n' "$details" | sed -n 's/^Identifier=//p' | head -n 1)"
  want="$(expected_identifier "$name")"
  [ "$identifier" = "$want" ] || die "$name: identifier is '${identifier}', expected '$want'"

  this_team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  case "$this_team" in
    ''|'not set') die "$name: no TeamIdentifier" ;;
  esac
  if [ -n "$expected_team" ] && [ "$this_team" != "$expected_team" ]; then
    die "$name: TeamIdentifier $this_team, expected $expected_team"
  fi
  if [ -z "$team" ]; then
    team="$this_team"
  elif [ "$this_team" != "$team" ]; then
    die "$name: TeamIdentifier $this_team differs from $team"
  fi

  entitlements="$("$codesign_bin" -d --entitlements - --xml "$f" 2>/dev/null || true)"
  if printf '%s' "$entitlements" | grep -q 'com.apple.security.get-task-allow'; then
    die "$name: carries the debug-only get-task-allow entitlement"
  fi

  notarized=no
  if [ "$require_notarized" = 1 ]; then
    "$codesign_bin" --verify --strict --check-notarization --test-requirement='=notarized' --verbose=2 "$f" \
      || die "$name: not notarized (no ticket found online)"
    notarized=yes
  fi

  echo "ok: $name identifier=$identifier team=$this_team flags=$flags notarized=$notarized"
  checked=$((checked + 1))
done

[ "$checked" -ge 2 ] || die "only $checked Mach-O binaries found in $bin_dir"
suffix=""
[ "$require_notarized" = 1 ] && suffix=" + notarization"
echo "verified $checked Developer ID + hardened runtime + timestamp$suffix signatures (team $team)"
