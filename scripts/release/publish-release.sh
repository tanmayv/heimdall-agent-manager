#!/usr/bin/env bash
# Publish a GitHub Release without ever changing a published one (report §6.5
# item 3, chain task T6). Used by the "Publish GitHub Release" job of
# .github/workflows/release-local-binaries.yml. Needs GH_REPO=<owner>/<repo>.
#
#   publish-release.sh check-unpublished <tag>
#       Exit 0 when <tag> has no release or only drafts, 3 when a published
#       release carries it (nothing may change it), 2 when the lookup failed.
#
#   publish-release.sh publish --tag <tag> --commit <sha> --notes-file <file>
#       [--prerelease] [--draft] -- <asset file>...
#       1. Every release carrying <tag> is listed (REST, all pages). A
#          published one -> exit 3 before any write call.
#       2. Every draft carrying <tag> is deleted by id: drafts are never
#          public, left by failed runs or the `draft` input, and recreating is
#          the only way to guarantee the asset set is exactly this run's files.
#       3. A new draft is created and its id kept; every later step addresses
#          THAT id, never the tag, so another draft for the same tag can never
#          be verified or published by mistake.
#       4. The assets are uploaded to that id, then the draft must hold exactly
#          these names with exactly these bytes (GitHub's sha256 `digest`, or
#          a download when the API has none). Mismatch -> exit 1, unpublished.
#       5. --draft: stop here. Otherwise PATCH draft=false on that id, then
#          check that it is the only release for <tag> and still holds the
#          verified assets.
#       Assets are never uploaded to, replaced on, or deleted from a published
#       release; with the repository's "release immutability" setting on,
#       GitHub additionally locks them (and the tag) at step 5. The workflow
#       also serialises release jobs per version (job-level concurrency).
#
# Every gh call goes through retry_transient (scripts/release/gh-retry.sh).
# Exit codes: 0 ok, 1 verification or API failure, 2 usage or lookup error,
# 3 already published (refused, nothing changed).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/gh-retry.sh
source "$script_dir/gh-retry.sh"

die() { echo "publish-release: $*" >&2; exit 2; }

repo="${GH_REPO:-}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GH_REPO must be <owner>/<repo>, not '$repo'"
api="repos/$repo/releases"

valid_tag() { [[ "$1" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || die "invalid release tag: $1"; }

# list_tag_releases <tag>: writes "<id> <draft>" lines for every release
# carrying <tag> to $work/tagged (all pages; drafts included for our token).
_list_releases() {
  gh api --paginate "$api?per_page=100" > "$work/releases.json"
}
list_tag_releases() {
  local rc=0
  retry_transient "List releases" _list_releases || rc=$?
  [ "$rc" -eq 0 ] || { echo "Could not list the releases of $repo." >&2; exit 2; }
  # --paginate prints one JSON array per page; jq reads them in sequence.
  jq -r --arg t "$1" '.[] | select(.tag_name == $t) | "\(.id) \(.draft)"' "$work/releases.json" > "$work/tagged" \
    || { echo "Could not parse the release list of $repo." >&2; exit 2; }
}

refuse_published() {
  {
    echo "::error::Release $1 is already published. Published releases are immutable:"
    echo "this run changes nothing (no asset is uploaded, replaced or deleted)."
    echo "Ship new bytes under a new tag instead."
  } >&2
  exit 3
}

# refuse_if_published <tag>: lists, refuses on any published release.
refuse_if_published() {
  list_tag_releases "$1"
  if grep -q ' false$' "$work/tagged"; then refuse_published "$1"; fi
  return 0
}

cmd_check_unpublished() {
  [ "$#" -eq 1 ] || die "usage: check-unpublished <tag>"
  valid_tag "$1"
  refuse_if_published "$1"
  local drafts
  drafts="$(grep -c ' true$' "$work/tagged" || true)"
  if [ "$drafts" -eq 0 ]; then
    echo "No release exists for $1."
  else
    echo "Release $1 exists only as $drafts draft(s); a publishing run replaces them."
  fi
}

# delete_release <id>: a retry whose first attempt landed sees 404.
delete_release() {
  local status=0
  gh api -X DELETE "$api/$1" 2>"$_err" >/dev/null || status=$?
  if [ "$status" -ne 0 ]; then
    grep -q 'HTTP 404' "$_err" && return 0
    cat "$_err" >&2
    return "$status"
  fi
}

delete_drafts() {
  local id draft
  while read -r id draft; do
    [ "$draft" = true ] || continue
    echo "Deleting unpublished draft $id of $1 (left by an earlier run or attempt)."
    retry_transient "Delete draft $id" delete_release "$id" || exit 1
  done < "$work/tagged"
}

# release_json <id>: GET the release by id into $work/release.json.
release_json() {
  gh api "$api/$1" > "$work/release.json"
}

expected_assets() {
  local f
  for f in "$@"; do
    printf '%s %s\n' "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
  done | LC_ALL=C sort
}

# remote_assets: "name sha256" from $work/release.json. Uses the API digest;
# an asset without one is downloaded by id and hashed (fail closed).
_download_asset() {
  gh api -H 'Accept: application/octet-stream' "$api/assets/$1" > "$work/dl.bin"
}
remote_assets() {
  local aid name digest
  jq -r '.assets[] | "\(.id) \(.name) \(.digest // "-")"' "$work/release.json" > "$work/remote.raw"
  while read -r aid name digest; do
    case "$digest" in
      sha256:*) printf '%s %s\n' "$name" "${digest#sha256:}" ;;
      *)
        # Progress lines go to stderr: stdout is the asset list.
        retry_transient "Download $name (no API digest)" _download_asset "$aid" >&2
        printf '%s %s\n' "$name" "$(sha256sum "$work/dl.bin" | cut -d' ' -f1)"
        ;;
    esac
  done < "$work/remote.raw" | LC_ALL=C sort
}

# check_release <id> <tag> <want-draft> <when>: the id still carries <tag>,
# has the expected draft flag and exactly the verified assets.
check_release() {
  local id="$1" tag="$2" want_draft="$3" when="$4" got rc=0
  retry_transient "Read release $id" release_json "$id" || rc=$?
  [ "$rc" -eq 0 ] || { echo "::error::Could not read release $id ($when)." >&2; return 1; }
  got="$(jq -r '"\(.tag_name) \(.draft)"' "$work/release.json")"
  if [ "$got" != "$tag $want_draft" ]; then
    echo "::error::Release $id ($when) is '$got', expected '$tag $want_draft'." >&2
    return 1
  fi
  remote_assets > "$work/remote"
  if ! diff -u "$work/expected" "$work/remote" > "$work/assets.diff"; then
    echo "::error::Release $tag id $id ($when) does not hold exactly the verified assets (- expected, + on GitHub):" >&2
    cat "$work/assets.diff" >&2
    return 1
  fi
  echo "Release $tag id $id ($when) holds exactly the $(wc -l < "$work/expected") verified assets."
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
  if [ -z "$tag" ] || [ -z "$commit" ] || [ ! -f "$notes" ]; then
    die "publish needs --tag, --commit and an existing --notes-file"
  fi
  valid_tag "$tag"
  [ "$#" -gt 0 ] || die "publish needs at least one asset after --"
  local f names
  for f in "$@"; do [ -f "$f" ] || die "missing asset: $f"; done
  names="$(for f in "$@"; do basename "$f"; done | LC_ALL=C sort)"
  [ -z "$(uniq -d <<< "$names")" ] || die "duplicate asset names: $(uniq -d <<< "$names" | tr '\n' ' ')"
  expected_assets "$@" > "$work/expected"

  refuse_if_published "$tag"
  delete_drafts "$tag"

  # Create + upload is one retry unit. Every attempt after the first deletes
  # EVERY draft for the tag, not just the id it saw: a POST can be applied
  # server-side yet answer 502/timeout, leaving a draft whose id we never got.
  # Safe because the job-level concurrency group serialises runs per version.
  release_id=""
  create_attempted=false
  create_and_upload() {
    release_id=""
    refuse_if_published "$tag"
    if [ "$create_attempted" = true ]; then delete_drafts "$tag"; fi
    create_attempted=true
    gh api -X POST "$api" -f tag_name="$tag" -f target_commitish="$commit" -f name="$tag" \
      -F draft=true -F prerelease="$prerelease" -F body=@"$notes" > "$work/created.json" || return $?
    release_id="$(jq -r .id "$work/created.json")"
    [[ "$release_id" =~ ^[0-9]+$ ]] || { echo "create returned no release id" >&2; release_id=""; return 1; }
    echo "Created draft $release_id for $tag."
    local upload_url file name
    upload_url="$(jq -r '.upload_url | sub("\\{.*$"; "")' "$work/created.json")"
    case "$upload_url" in
      "https://uploads.github.com/repos/$repo/releases/$release_id/assets") ;;
      *) echo "unexpected upload_url '$upload_url' for draft $release_id" >&2; return 1 ;;
    esac
    for file in "$@"; do
      name="$(basename "$file")"
      # Percent-encode: a '+' (SemVer build metadata) would otherwise arrive as a space.
      gh api -X POST -H 'Content-Type: application/octet-stream' --input "$file" \
        "$upload_url?name=$(jq -rn --arg n "$name" '$n|@uri')" > /dev/null || return $?
      echo "  uploaded $name"
    done
  }
  retry_transient "Create draft $tag and upload $# assets" create_and_upload "$@" || {
    echo "Creating the draft of $tag failed; see the attempts above." >&2; exit 1; }

  check_release "$release_id" "$tag" true "draft" || exit 1

  if [ "$draft" = true ]; then
    echo "Release $tag left as verified draft $release_id (draft input); publish it by hand. Publishing makes it immutable."
    return 0
  fi

  # Publishing is the only write after the check, and it targets this id only:
  # if the draft vanished, the PATCH fails and nothing else is published.
  publish_draft() {
    release_json "$release_id" || return $?
    if [ "$(jq -r .draft "$work/release.json")" = false ]; then return 0; fi   # an earlier attempt landed
    gh api -X PATCH "$api/$release_id" -F draft=false > /dev/null
  }
  retry_transient "Publish release $tag (id $release_id)" publish_draft || {
    echo "Publishing $tag (id $release_id) failed; this run published nothing." >&2; exit 1; }

  check_release "$release_id" "$tag" false "published" || exit 1
  local immutable
  immutable="$(jq -r 'if .immutable == null then "unknown" else .immutable end' "$work/release.json")"
  list_tag_releases "$tag"
  if [ "$(cat "$work/tagged")" != "$release_id false" ]; then
    echo "::error::After publishing, $tag is carried by more than release $release_id:" >&2
    cat "$work/tagged" >&2
    exit 1
  fi
  if [ "$immutable" = true ]; then
    echo "Release $tag is published and immutable (assets and tag locked by GitHub)."
  else
    echo "::warning::Release $tag is published but GitHub reports immutable=$immutable; enable 'Release immutability' in the repository settings (docs/release-signing.md)."
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
