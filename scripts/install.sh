#!/usr/bin/env bash
# Heimdall Bridge bootstrap for Linux, macOS and Termux:
#
#   curl -fsSL https://install.ninjy.ai | bash -s -- --hub https://hub.example.com
#   curl -fsSL https://install.ninjy.ai | HEIMDALL_HUB=https://hub.example.com bash
#
# It only resolves a release, downloads this machine's bundle, verifies it
# against the release's SHA256SUMS and runs `ham-bridge setup --headless` from
# it with every other argument passed through (--interactive drops --headless
# so ham-bridge opens the approval page: the desktop installers use it).
# Detecting, installing, enrolling, the user service, extensions and rollback
# all live in ham-bridge (`ham-bridge setup --help`); updates use
# `ham-bridge update --version`. Behaviour, flags and exit codes:
# docs/specs/bridge-installer-contract.md (install.ps1 implements the same).
# Self-contained: it makes no assumption about where it was fetched from
# (install.ninjy.ai, a release asset or main), never reads stdin and needs no
# TTY. Runs under bash 3.2 (macOS /bin/bash) and later.
REPO=tanmayv/heimdall-releases
usage() {
  cat <<'HELP'
Usage: install.sh --hub URL [--profile NAME] [--version TAG|latest]
                  [--bundle FILE --checksum-file FILE] [--interactive]
                  [other ham-bridge setup flags: --new-bridge, --reuse-bridge ID,
                   --reenroll, --allow-downgrade, --separate-account,
                   --replace-other-account, --json-progress ...]
       install.sh --uninstall [--hub URL [--profile NAME]] [ham-bridge uninstall flags]

Headless one-liner (no TTY or browser needed on this machine; approve the
pairing code it prints from any device signed in to your Ninjy account):
  curl -fsSL https://install.ninjy.ai | bash -s -- --hub https://hub.example.com
  curl -fsSL https://install.ninjy.ai | HEIMDALL_HUB=https://hub.example.com bash
Safe to re-run: a healthy enrolled bridge is left untouched.

  --hub URL          Hub origin (alias --hub-url; env HEIMDALL_HUB). Required.
  --profile NAME     Profile, [a-z0-9][a-z0-9-]{0,30} (alias --name;
                     env HEIMDALL_BRIDGE_NAME). Default profile when empty.
  --version TAG      Release to bootstrap from (env HEIMDALL_VERSION). Default
                     latest = GitHub's latest (promoted, stable) release; then an
                     installed bridge keeps its version (--keep-version). With
                     a TAG (passed on as setup --version) an installed bridge is
                     moved to it; an older TAG is refused (exit 5) unless
                     --allow-downgrade is given (releases after v0.5.77; up to
                     v0.5.77 setup ignores --version and installs the TAG).
  --bundle FILE --checksum-file FILE
                     Use an already-downloaded bundle (verified first); an
                     installed bridge is moved to the bundle's version.
  --interactive      Open the approval page in a browser (no --headless).
  --uninstall        Run ham-bridge uninstall instead (e.g. --purge --yes).
Flags win over environment variables. Everything else goes to ham-bridge.

Exit codes: 0 done, 1 setup failed (previous state restored), 2 usage error,
3 bootstrap failed (nothing touched), 4 installed but not enrolled (re-run),
5 refused (needs the named flag), 6 busy, 7 rollback incomplete.
Requires curl, tar and sha256sum (or shasum). Run as your login user, not root.
HELP
}
# fail CODE MESSAGE: 2 = usage error, 3 = bootstrap failure (nothing touched).
fail() { printf '[ERROR] %s\n' "$2" >&2; exit "$1"; }
log() { printf '[%s] %s\n' "$1" "$2" >&2; }
fetch() {
  curl --fail --location --silent --show-error --connect-timeout 15 \
    --max-time 600 --speed-limit 1024 --speed-time 60 "$1" --output "$2"
}
json_tokens() {
  LC_ALL=C grep -oE '"([^"\\]|\\.)*"|[][{}:,]|true|false|null|-?[0-9][0-9.eE+-]*' "$1"
}
# The fields of one GitHub release object ($1) the installer needs, one per
# line: `tag <tag_name>`, `draft`, `prerelease`, `asset <name>`.
# Exit 2: not a JSON object.
release_fields() {
  { json_tokens "$1" || true; } | LC_ALL=C awk '
    # The text of a JSON string token; \uXXXX escapes are kept as they are.
    function unq(s,  out, c) {
      s = substr(s, 2, length(s) - 2); out = ""
      while (match(s, /\\./)) {
        c = substr(s, RSTART + 1, 1)
        out = out substr(s, 1, RSTART - 1) (c == "n" ? "\n" : c == "t" ? "\t" : c == "r" ? "\r" : c == "u" ? "\\u" : c)
        s = substr(s, RSTART + 2)
      }
      return out s
    }
    function truthy(t) { return !(t == "false" || t == "null" || t == "0" || t == "\"\"") }
    function value(t) {
      if (d == 1 && typ[1] == "o") {
        if (key[1] == "tag_name" && t ~ /^"/) print "tag " unq(t)
        else if (key[1] == "draft" && truthy(t)) print "draft"
        else if (key[1] == "prerelease" && truthy(t)) print "prerelease"
      } else if (d == 3 && key[1] == "assets" && typ[2] == "a" && typ[3] == "o" && key[3] == "name" && t ~ /^"/) {
        print "asset " unq(t)
      }
    }
    NR == 1 && $0 != "{" { exit 2 }
    { t = $0; seen = 1 }
    t == "{" || t == "[" { d++; typ[d] = (t == "{") ? "o" : "a"; ek[d] = (t == "{"); key[d] = ""; next }
    t == "}" || t == "]" { d--; next }
    t == ":" { ek[d] = 0; next }
    t == "," { if (typ[d] == "o") ek[d] = 1; next }
    typ[d] == "o" && ek[d] { key[d] = unq(t); next }
    { value(t) }
    END { if (!seen) exit 2 }'
}
# Stable release tag for target $2 from GET /releases/latest, written to
# stdout; the release must carry SHA256SUMS and this target's bundle. Never
# falls back to an older release and never reads a list page (report F9).
resolve_stable() {
  local work="$1" target="$2" fields tag reason
  if ! fetch "https://api.github.com/repos/$REPO/releases/latest" "$work/latest.json" 2> "$work/latest.err"; then
    reason="$(sed -e 's/^curl: ([0-9]*) //' "$work/latest.err" | tail -n 1)"
    fail 3 "Cannot resolve the stable release from GitHub (${reason:-request failed}); pass --version TAG."
  fi
  fields="$(release_fields "$work/latest.json")" ||
    fail 3 'Cannot resolve the stable release from GitHub (the response is not a release); pass --version TAG.'
  tag="$(printf '%s\n' "$fields" | sed -n 's/^tag //p' | head -n 1)"
  [ -n "$tag" ] || fail 3 'Cannot resolve the stable release from GitHub (no tag_name in the response); pass --version TAG.'
  if printf '%s\n' "$fields" | grep -qxE 'draft|prerelease'; then
    fail 3 "Cannot resolve the stable release from GitHub ($tag is not a promoted release); pass --version TAG."
  fi
  printf '%s\n' "$fields" | grep -qxF 'asset SHA256SUMS' ||
    fail 3 "Stable release $tag has no SHA256SUMS for $target; pass --version TAG."
  printf '%s\n' "$fields" | grep -qxF "asset heimdall-local-$target-$tag.tar.gz" ||
    fail 3 "Stable release $tag has no bundle for $target; pass --version TAG."
  printf '%s\n' "$tag"
}
sha256_of() {
  local out
  if command -v sha256sum >/dev/null; then out="$(sha256sum < "$1")" || return 1
  else out="$(shasum -a 256 < "$1")" || return 1; fi
  printf '%s\n' "${out%% *}"
}
# Whether file $2 matches the single SHA256SUMS ($1) entry named $3.
sha256_matches() {
  local expected actual
  expected="$(awk -v n="$3" '{ sub(/\r$/, "") } NF == 2 { f = $2; sub(/^\*+/, "", f); if (f == n) { c++; h = tolower($1) } }
    END { if (c == 1) print h; else exit 1 }' "$1")" || return 1
  actual="$(sha256_of "$2")" || return 1
  [ -n "$actual" ] && [ "$actual" = "$expected" ]
}
# Release target: <os>-<arch>, termux-<arch> on Android (its seccomp kills the
# glibc linux-* binaries; releases before v0.3.29 have no termux bundle).
detect_target() {
  local os arch
  case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) fail 3 "Unsupported platform $(uname -s); supported: Linux and macOS (Windows: install.ps1)." ;; esac
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) fail 3 "Unsupported architecture $(uname -m); supported: amd64 and arm64." ;; esac
  if [ -n "${TERMUX_VERSION:-}" ]; then os=termux
  else case "${PREFIX:-}" in /data/data/com.termux|/data/data/com.termux/*) os=termux ;; esac; fi
  printf '%s-%s\n' "$os" "$arch"
}
need() { command -v "$1" >/dev/null || fail 3 "$2 is required but was not found on PATH; install it and re-run."; }
main() {
  set -euo pipefail
  local hub='' profile='' version='' bundle='' sums='' verb=setup headless=--headless
  local hub_set='' profile_set='' version_set=''
  local -a pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hub|--hub-url|--profile|--name|--version|--bundle|--checksum-file)
        [ "$#" -ge 2 ] && [ -n "$2" ] || fail 2 "$1 requires a value."
        case "$1" in
          --hub|--hub-url) hub="$2"; hub_set=1 ;;
          --profile|--name) profile="$2"; profile_set=1 ;;
          --version) version="$2"; version_set=1 ;;
          --bundle) bundle="$2" ;;
          *) sums="$2" ;;
        esac
        shift 2 ;;
      --uninstall) verb=uninstall; shift ;;
      --interactive) headless=''; shift ;;
      --help|-h) usage; return 0 ;;
      *) pass+=("$1"); shift ;;
    esac
  done
  # An environment variable is only the default for an option that is absent.
  [ -n "$hub_set" ] || hub="${HEIMDALL_HUB:-}"
  [ -n "$profile_set" ] || profile="${HEIMDALL_BRIDGE_NAME:-}"
  [ -n "$version_set" ] || version="${HEIMDALL_VERSION:-}"
  [ "$(id -u)" != 0 ] || fail 2 'Run as your login user without sudo; the bridge is a user service.'
  [ "$verb" = uninstall ] || [ -n "$hub" ] ||
    fail 2 'No hub given: pass --hub URL or set HEIMDALL_HUB (see --help).'
  if [ -n "$profile" ]; then
    [[ "$profile" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || fail 2 "Invalid profile \"$profile\": use [a-z0-9][a-z0-9-]{0,30}."
  fi
  [ "$version" != latest ] || version=''
  # Only when the script resolves the release itself (no --version /
  # HEIMDALL_VERSION, no --bundle) must a re-run never change an installed
  # bridge's version (spec §7, S8a): ham-bridge setup keeps it. An explicit
  # release or bundle means "install this one" (S8b; an older explicit release
  # is refused, S8c), e.g. the macOS .pkg postinstall. Releases before
  # --keep-version ignore the flag.
  local keep=''
  [ -n "$version" ] || [ -n "$bundle" ] || keep=--keep-version
  # A concrete TAG the user asked for (not latest, not a release this script
  # resolved) reaches setup as --version, so an installed newer bridge is not
  # downgraded without --allow-downgrade (S8c, exit 5). With --bundle, setup
  # checks the TAG names that bundle (exit 2 otherwise).
  local requested="$version"
  if [ -n "$version" ]; then
    [[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || fail 2 "Invalid release tag: $version"
  fi
  if [ -n "$bundle" ] || [ -n "$sums" ]; then
    [ -f "$bundle" ] && [ -f "$sums" ] || fail 2 '--bundle and --checksum-file must both name regular files.'
  else
    need curl curl
  fi
  need tar tar
  command -v sha256sum >/dev/null || command -v shasum >/dev/null ||
    fail 3 'sha256sum (coreutils) or shasum is required but neither was found on PATH; install one and re-run.'
  local target work
  target="$(detect_target)" || exit $?
  work="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-install.XXXXXX")" || fail 3 'Cannot create a temporary directory.'
  # shellcheck disable=SC2064 # expanded now on purpose: $work is quoted with %q
  trap "$(printf 'rm -rf %q' "$work")" EXIT
  local archive
  if [ -n "$bundle" ]; then
    archive="$(basename "$bundle")"
    # The desktop apps stage their bundle unversioned (heimdall-local-<target>.tar.gz).
    case "$archive" in heimdall-local-"$target"-*.tar.gz|heimdall-local-"$target".tar.gz) ;; *) fail 3 "Bundle $archive is not for this machine ($target)." ;; esac
    cp "$sums" "$work/SHA256SUMS"; cp "$bundle" "$work/$archive"
  else
    # Releases start as prereleases (canary candidates); stable is the promoted
    # release GitHub reports as latest. An explicit --version may be any release.
    [ -n "$version" ] || version="$(resolve_stable "$work" "$target")" || exit $?
    archive="heimdall-local-$target-$version.tar.gz"
    local base="https://github.com/$REPO/releases/download/$version"
    log INFO "Release $version ($target)"
    fetch "$base/SHA256SUMS" "$work/SHA256SUMS" || fail 3 "Release $version has no SHA256SUMS (unknown tag?)."
    log INFO "Downloading $archive"
    fetch "$base/$archive" "$work/$archive" || fail 3 "Release $version has no $archive."
  fi
  sha256_matches "$work/SHA256SUMS" "$work/$archive" "$archive" || fail 3 'SHA-256 verification failed; nothing installed.'
  log OK "SHA-256 verified: $archive"
  mkdir "$work/bundle"
  tar -xzf "$work/$archive" -C "$work/bundle" || fail 3 'Cannot unpack the bundle; nothing installed.'
  local bridge="$work/bundle/bin/ham-bridge"
  [ -f "$bridge" ] && [ ! -L "$bridge" ] || fail 3 'The bundle has no bin/ham-bridge.'
  chmod 755 "$bridge"
  # Exactly one --hub / --profile reaches ham-bridge, ahead of the pass-through.
  local -a argv=()
  [ -z "$hub" ] || argv+=(--hub "$hub")
  [ -z "$profile" ] || argv+=(--profile "$profile")
  [ "$verb" = uninstall ] || [ -z "$keep" ] || argv+=("$keep")
  [ "$verb" = uninstall ] || [ -z "$requested" ] || argv+=(--version "$requested")
  # ham-bridge copies what it needs out of the bundle, so the temporary copy is
  # removed afterwards. stdin is not the script's: `curl | bash` already read it.
  # ham-bridge's exit code is returned unchanged.
  local status=0
  if [ "$verb" = uninstall ]; then
    "$bridge" uninstall ${argv[@]+"${argv[@]}"} ${pass[@]+"${pass[@]}"} < /dev/null || status=$?
  else
    "$bridge" setup ${headless:+"$headless"} ${argv[@]+"${argv[@]}"} ${pass[@]+"${pass[@]}"} < /dev/null || status=$?
  fi
  exit "$status"
}
main "$@"
