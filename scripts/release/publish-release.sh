#!/usr/bin/env bash
# Publish a GitHub Release without ever changing a published one (report §6.5
# item 3, chain task T6). Used by the "Publish GitHub Release" job of
# .github/workflows/release-local-binaries.yml.
#
#   publish-release.sh check-unpublished <tag>
#       Exit 0 when <tag> has no release or only a draft, 3 when a published
#       release exists (nothing may change it), 2 when the lookup failed.
#
#   publish-release.sh publish --tag <tag> --commit <sha> --notes-file <file>
#       [--prerelease] [--draft] -- <asset file>...
#       1. A published release for <tag> -> exit 3 before any write call.
#       2. A leftover draft (failed earlier run, or the `draft` input) is
#          deleted: drafts are never public, and recreating one is the only
#          way to guarantee its asset set is exactly this run's files.
#       3. Create the release as a DRAFT with every asset.
#       4. Check the draft holds exactly these assets (names) with exactly
#          these bytes (GitHub's sha256 `digest`, or a download when the API
#          has none). Mismatch -> exit 1, the draft stays unpublished.
#       5. --draft: stop here. Otherwise publish (draft=false), then check
#          again that the published assets are the ones verified.
#       Assets are never uploaded to, replaced on, or deleted from a published
#       release; with the repository's "release immutability" setting on,
#       GitHub additionally locks them (and the tag) at step 5.
#
# Every gh call goes through retry_transient (scripts/release/gh-retry.sh).
# Exit codes: 0 ok, 1 verification failed, 2 usage or lookup error,
# 3 already published (refused, nothing changed).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/gh-retry.sh
source "$script_dir/gh-retry.sh"

die() { echo "publish-release: $*" >&2; exit 2; }

# release_state <tag>: prints none|draft|published. Returns 2 on a lookup
# error (stderr carries gh's message so retry_transient can classify it).
release_state() {
  local tag="$1" out status=0
  out="$(gh release view "$tag" --json isDraft --jq .isDraft 2>"$_err")" || status=$?
  if [ "$status" -ne 0 ]; then
    if grep -qi 'release not found' "$_err"; then
      echo none; return 0
    fi
    cat "$_err" >&2
    return 2
  fi
  case "$out" in
    true) echo draft ;;
    false) echo published ;;
    *) echo "unexpected isDraft value for $tag: '$out'" >&2; return 2 ;;
  esac
}

# lookup_state <tag>: sets $state, retrying transient lookup errors.
lookup_state() {
  local rc=0
  state=""
  retry_transient "Look up release $1" _set_state "$1" || rc=$?
  [ "$rc" -eq 0 ] || { echo "Could not determine the state of release $1." >&2; exit 2; }
}
_set_state() { state="$(release_state "$1")"; }

refuse_published() {
  {
    echo "::error::Release $1 is already published. Published releases are immutable:"
    echo "this run changes nothing (no asset is uploaded, replaced or deleted)."
    echo "Ship new bytes under a new tag instead."
  } >&2
  exit 3
}

cmd_check_unpublished() {
  [ "$#" -eq 1 ] || die "usage: check-unpublished <tag>"
  lookup_state "$1"
  case "$state" in
    none) echo "No release exists for $1." ;;
    draft) echo "Release $1 exists only as a draft; a publishing run will replace it." ;;
    published) refuse_published "$1" ;;
  esac
}

# delete_draft <tag>: a retry whose first attempt landed sees "not found".
delete_draft() {
  local tag="$1" status=0
  gh release delete "$tag" --yes 2>"$_err" || status=$?
  if [ "$status" -ne 0 ]; then
    grep -qi 'not found' "$_err" && return 0
    cat "$_err" >&2
    return "$status"
  fi
}

# expected_assets <file>...: "name sha256" lines, sorted.
expected_assets() {
  local f
  for f in "$@"; do
    printf '%s %s\n' "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
  done | LC_ALL=C sort
}

# remote_assets <tag>: "name sha256" lines, sorted. Uses the API digest; an
# asset without one is downloaded and hashed (fail closed, never skipped).
_remote_raw() {
  gh release view "$1" --json assets --jq '.assets[] | "\(.name) \(.digest // "")"' > "$work/remote.raw"
}
_download_asset() {
  gh release download "$1" --pattern "$2" --dir "$work/dl" --clobber
}
remote_assets() {
  local tag="$1" name digest
  # Progress lines go to stderr: stdout is the asset list.
  retry_transient "List assets of release $tag" _remote_raw "$tag" >&2
  while read -r name digest; do
    [ -n "$name" ] || continue
    case "$digest" in
      sha256:*) printf '%s %s\n' "$name" "${digest#sha256:}" ;;
      *)
        mkdir -p "$work/dl"
        retry_transient "Download $name (no API digest)" _download_asset "$tag" "$name" >&2
        printf '%s %s\n' "$name" "$(sha256sum "$work/dl/$name" | cut -d' ' -f1)"
        ;;
    esac
  done < "$work/remote.raw" | LC_ALL=C sort
}

# check_assets <tag> <when>: the release's assets must equal $work/expected.
check_assets() {
  remote_assets "$1" > "$work/remote"
  if ! diff -u "$work/expected" "$work/remote" > "$work/assets.diff"; then
    echo "::error::Release $1 ($2) does not hold exactly the verified assets (- expected, + on GitHub):" >&2
    cat "$work/assets.diff" >&2
    return 1
  fi
  echo "Release $1 ($2) holds exactly the $(wc -l < "$work/expected") verified assets."
}

cmd_publish() {
  local tag="" commit="" notes="" prerelease=false draft=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag) tag="${2:-}"; shift 2 ;;
      --commit) commit="${2:-}"; shift 2 ;;
      --notes-file) notes="${2:-}"; shift 2 ;;
      --prerelease) prerelease=true; shift ;;
      --draft) draft=true; shift ;;
      --) shift; break ;;
      *) die "unknown publish argument: $1" ;;
    esac
  done
  [ -n "$tag" ] && [ -n "$commit" ] && [ -f "$notes" ] || die "publish needs --tag, --commit and an existing --notes-file"
  [ "$#" -gt 0 ] || die "publish needs at least one asset after --"
  local f names
  for f in "$@"; do [ -f "$f" ] || die "missing asset: $f"; done
  names="$(for f in "$@"; do basename "$f"; done | LC_ALL=C sort)"
  [ -z "$(uniq -d <<< "$names")" ] || die "duplicate asset names: $(uniq -d <<< "$names" | tr '\n' ' ')"
  expected_assets "$@" > "$work/expected"

  lookup_state "$tag"
  case "$state" in
    published) refuse_published "$tag" ;;
    draft)
      echo "Deleting the unpublished draft of $tag left by an earlier run; it is recreated below."
      retry_transient "Delete draft $tag" delete_draft "$tag" || exit 1
      ;;
  esac

  local create_flags=(--draft --title "$tag" --target "$commit" --notes-file "$notes")
  if [ "$prerelease" = true ]; then create_flags+=(--prerelease); fi
  # A failed attempt may have left a partial draft: start over from nothing,
  # and never touch a release that got published meanwhile.
  create_attempted=false
  create_draft() {
    if [ "$create_attempted" = true ]; then
      local s
      s="$(release_state "$tag")" || return 2
      case "$s" in
        published) refuse_published "$tag" ;;
        draft) delete_draft "$tag" || return $? ;;
      esac
    fi
    create_attempted=true
    gh release create "$tag" "$@" "${create_flags[@]}"
  }
  retry_transient "Create draft release $tag" create_draft "$@" || {
    echo "Creating the draft of $tag failed; see the attempts above." >&2; exit 1; }

  lookup_state "$tag"
  [ "$state" = draft ] || { echo "::error::Release $tag should be a draft right after creation but is '$state'." >&2; exit 1; }
  check_assets "$tag" "draft" || exit 1

  if [ "$draft" = true ]; then
    echo "Release $tag left as a verified draft (draft input); publish it by hand. Publishing makes it immutable."
    return 0
  fi

  # Publishing is the only write to the release after its assets were checked.
  publish_draft() {
    local s
    s="$(release_state "$tag")" || return 2
    [ "$s" = published ] && return 0   # an earlier attempt landed
    gh release edit "$tag" --draft=false
  }
  retry_transient "Publish release $tag" publish_draft || {
    echo "Publishing $tag failed; it stays an unpublished draft." >&2; exit 1; }

  lookup_state "$tag"
  [ "$state" = published ] || { echo "::error::Release $tag is '$state' after publishing." >&2; exit 1; }
  check_assets "$tag" "published" || exit 1
  local immutable=""
  _immutable() { immutable="$(gh release view "$tag" --json isImmutable --jq .isImmutable)"; }
  retry_transient "Read immutability of $tag" _immutable || immutable=unknown
  if [ "$immutable" = true ]; then
    echo "Release $tag is published and immutable (assets and tag locked by GitHub)."
  else
    echo "::warning::Release $tag is published but GitHub reports isImmutable=$immutable; enable 'Release immutability' in the repository settings (docs/release-signing.md)."
  fi
}

work="$(mktemp -d)"
_err="$work/gh.err"
trap 'rm -rf "$work"' EXIT

case "${1:-}" in
  check-unpublished) shift; cmd_check_unpublished "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  *) die "usage: $0 check-unpublished <tag> | publish --tag <tag> --commit <sha> --notes-file <f> [--prerelease] [--draft] -- <asset>..." ;;
esac
