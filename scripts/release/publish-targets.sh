#!/usr/bin/env bash
# Publish one release to every release repository (releases-repo migration).
# Runs scripts/release/publish-release.sh once per target, each with its own
# repository and token, so the immutable-release rules (never change a
# published release, verified assets, draft -> publish) hold on both:
#
#   1. RELEASES_REPO (default tanmayv/heimdall-releases, public): the future
#      home of every release artifact. Token: RELEASES_TOKEN, a GitHub App
#      installation token scoped to that repository. The repository holds no
#      source, so the tag is created on its default branch and the release
#      notes link the source commit instead.
#   2. SOURCE_REPO (default $GITHUB_REPOSITORY): kept for the migration window
#      because already-installed bridges and desktops have it compiled in.
#      Token: SOURCE_TOKEN (the workflow's github.token). Switch it off with
#      PUBLISH_SOURCE_RELEASES=false once those clients have moved.
#
#   publish-targets.sh check-unpublished <tag>
#       Exit 0 only when no target has a published <tag> (drafts are fine);
#       3 when one does. Used before the builds: a rebuild would differ from
#       what is already published.
#   publish-targets.sh check-unpublished <tag> --allow-identical -- <asset>...
#       Same, but a target whose published <tag> holds exactly these assets
#       passes (a "re-run failed jobs" completing a half-done publish).
#   publish-targets.sh publish --tag <tag> --commit <sha> --notes-file <f>
#       [--prerelease] [--draft] -- <asset>...
#       Idempotent: a target that already holds exactly these assets is left
#       alone, so re-running the failed release job finishes the other target.
#       The releases repository goes first; if it fails nothing is published
#       on the source repository.
#
# Environment: RELEASES_TOKEN (required), SOURCE_TOKEN (required unless the
# source switch is off), RELEASES_REPO, SOURCE_REPO, PUBLISH_SOURCE_RELEASES
# (default true), SOURCE_URL (default $GITHUB_SERVER_URL/$SOURCE_REPO), and
# DRY_RUN=1 to print the plan without calling GitHub.
# Exit codes are publish-release.sh's: 0 ok, 1 failure, 2 usage/config, 3 refused.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "publish-targets: $*" >&2; exit 2; }

source_repo="${SOURCE_REPO:-${GITHUB_REPOSITORY:-}}"
releases_repo="${RELEASES_REPO:-tanmayv/heimdall-releases}"
publish_source="${PUBLISH_SOURCE_RELEASES:-true}"
dry_run="${DRY_RUN:-}"
repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

[[ "$releases_repo" =~ $repo_re ]] || die "RELEASES_REPO must be <owner>/<repo>, not '$releases_repo'"
case "$publish_source" in
  true) [[ "$source_repo" =~ $repo_re ]] || die "SOURCE_REPO must be <owner>/<repo>, not '$source_repo'" ;;
  false) ;;
  *) die "PUBLISH_SOURCE_RELEASES must be true or false, not '$publish_source'" ;;
esac
[ "$publish_source" = false ] || [ "$source_repo" != "$releases_repo" ] \
  || die "SOURCE_REPO and RELEASES_REPO are both $releases_repo"
source_url="${SOURCE_URL:-${GITHUB_SERVER_URL:-https://github.com}/$source_repo}"

# targets: "<kind> <repo> <token>" lines in publishing order.
targets=("releases $releases_repo ${RELEASES_TOKEN:-}")
[ "$publish_source" != true ] || targets+=("source $source_repo ${SOURCE_TOKEN:-}")
if [ -z "$dry_run" ]; then
  for t in "${targets[@]}"; do
    read -r kind repo token <<< "$t"
    [ -n "$token" ] || die "no token for the $kind repository $repo (set ${kind^^}_TOKEN)"
  done
fi
[ "$publish_source" = true ] || echo "Publishing to the source repository is switched off (PUBLISH_SOURCE_RELEASES=false)."

# run_target <kind> <repo> <token> <publish-release.sh args...>
run_target() {
  local kind="$1" repo="$2" token="$3"
  shift 3
  if [ -n "$dry_run" ]; then
    echo "[dry-run] $kind: GH_REPO=$repo publish-release.sh $*"
    return 0
  fi
  echo "== $kind repository $repo =="
  GH_REPO="$repo" GH_TOKEN="$token" "$script_dir/publish-release.sh" "$@"
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cmd_check() {
  [ "$#" -ge 1 ] || die "usage: check-unpublished <tag> [--allow-identical -- <asset>...]"
  local t kind repo token rc=0
  for t in "${targets[@]}"; do
    read -r kind repo token <<< "$t"
    run_target "$kind" "$repo" "$token" check-unpublished "$@" || rc=$?
    [ "$rc" -eq 0 ] || { echo "::error::$repo refused or failed (exit $rc)." >&2; exit "$rc"; }
  done
}

cmd_publish() {
  local tag="" commit="" notes="" pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tag) tag="${2:-}"; pass+=("$1" "$tag"); shift 2 ;;
      --commit) commit="${2:-}"; shift 2 ;;
      --notes-file) notes="${2:-}"; shift 2 ;;
      --prerelease|--draft) pass+=("$1"); shift ;;
      --) shift; break ;;
      *) die "unknown publish argument: $1" ;;
    esac
  done
  [ -n "$tag" ] && [ -n "$commit" ] && [ -f "$notes" ] || die "publish needs --tag, --commit and an existing --notes-file"
  [[ "$commit" =~ ^[0-9a-f]{7,64}$ ]] || [ -n "$dry_run" ] || die "--commit must be a hex commit sha, not '$commit'"
  local t kind repo token rc=0
  for t in "${targets[@]}"; do
    read -r kind repo token <<< "$t"
    if [ "$kind" = releases ]; then
      # No source here: the tag goes on the default branch, and the notes
      # point at the commit the release was built from.
      cp "$notes" "$work/notes-releases.md"
      printf '\n---\nBuilt from source commit [%s](%s/commit/%s).\n' "${commit:0:12}" "$source_url" "$commit" \
        >> "$work/notes-releases.md"
      run_target "$kind" "$repo" "$token" publish "${pass[@]}" --target-default-branch --allow-identical \
        --notes-file "$work/notes-releases.md" -- "$@" || rc=$?
    else
      run_target "$kind" "$repo" "$token" publish "${pass[@]}" --commit "$commit" --allow-identical \
        --notes-file "$notes" -- "$@" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      echo "::error::Publishing $tag to $repo failed (exit $rc)." >&2
      if [ "$kind" = source ]; then
        echo "The release is already published on $releases_repo. Re-run the failed release job (not the whole workflow):" >&2
        echo "it reuses the same build artifacts, so the identical-asset check lets it finish this repository." >&2
      fi
      exit "$rc"
    fi
  done
}

case "${1:-}" in
  check-unpublished) shift; cmd_check "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  *) die "usage: $0 check-unpublished <tag> [--allow-identical -- <asset>...] | publish --tag <tag> --commit <sha> --notes-file <f> [--prerelease] [--draft] -- <asset>..." ;;
esac
