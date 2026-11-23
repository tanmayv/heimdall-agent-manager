#!/usr/bin/env bash
# Integrity checks run by .github/workflows/promote-release.yml before a
# candidate becomes the stable Latest release (chain task T6).
#
#   check-promotion.sh <tag> <release.json> <workdir>
#
# <release.json> is `gh release view <tag> --json isDraft,isPrerelease,isImmutable,assets`.
# Fails closed (exit 1) unless:
#   1. the release has heimdall-release-manifest.json and its .minisig, and the
#      signature verifies with a key pinned in scripts/release/minisign/ of the
#      checked-out source (release-manifest.py: pinned key, trusted comment,
#      canonical form, not expired);
#   2. the manifest is for <tag>;
#   3. the release's bridge bundles (heimdall-local-*-<tag>.tar.gz|.zip) are
#      exactly the manifest's assets, and each downloaded bundle matches the
#      manifest's size and sha256;
#   4. the manifest and every bundle carry a GitHub build-provenance
#      attestation signed by release-local-binaries.yml of this repository,
#      built from refs/tags/<tag> (tag push) or refs/heads/$DEFAULT_BRANCH
#      (dispatch from the default branch); a dry run on any other branch
#      does not count;
#   5. when GitHub reports the release immutable, `gh release verify` and
#      `gh release verify-asset` pass for it. A mutable release only warns:
#      immutability is a repository setting (docs/release-signing.md).
# Exit codes: 0 ok, 1 rejected, 2 usage.

set -euo pipefail

[ "$#" -eq 3 ] || { echo "usage: $0 <tag> <release.json> <workdir>" >&2; exit 2; }
tag="$1" release_json="$2" work="$3"
repo="${GH_REPO:?GH_REPO must name owner/repo}"
default_branch="${DEFAULT_BRANCH:?DEFAULT_BRANCH must name the default branch}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest_tool=(python3 -I "$script_dir/release-manifest.py")
manifest=heimdall-release-manifest.json
signer="$repo/.github/workflows/release-local-binaries.yml"
mkdir -p "$work"

reject() { echo "::error::promotion of $tag rejected: $*" >&2; exit 1; }

has_asset() { jq -e --arg n "$1" '.assets | any(.name == $n)' "$release_json" > /dev/null; }

# 1. Signed manifest present and valid.
for name in "$manifest" "$manifest.minisig"; do
  has_asset "$name" || reject "missing asset $name (releases before the signed manifest cannot be promoted)"
done
gh release download "$tag" --dir "$work" --pattern "$manifest" --pattern "$manifest.minisig" --clobber
"${manifest_tool[@]}" verify --manifest "$work/$manifest" --signature "$work/$manifest.minisig" \
  || reject "the signed manifest does not verify"

# 2. For this tag.
manifest_tag="$(jq -r .tag "$work/$manifest")"
[ "$manifest_tag" = "$tag" ] || reject "manifest is for $manifest_tag, not $tag"

# 3. Bundles on the release == bundles in the manifest, bytes match.
jq -r '.targets[].asset' "$work/$manifest" | LC_ALL=C sort > "$work/manifest-assets"
jq -r --arg v "$tag" '.assets[].name
  | select(startswith("heimdall-local-") and (endswith("-" + $v + ".tar.gz") or endswith("-" + $v + ".zip")))' \
  "$release_json" | LC_ALL=C sort > "$work/release-assets"
if ! diff -u "$work/manifest-assets" "$work/release-assets" > "$work/assets.diff"; then
  cat "$work/assets.diff" >&2
  reject "bridge bundles on the release differ from the signed manifest (- manifest, + release)"
fi
mapfile -t bundles < "$work/manifest-assets"
[ "${#bundles[@]}" -gt 0 ] || reject "the manifest lists no bundles"
patterns=()
for name in "${bundles[@]}"; do patterns+=(--pattern "$name"); done
gh release download "$tag" --dir "$work" "${patterns[@]}" --clobber
"${manifest_tool[@]}" verify --manifest "$work/$manifest" --signature "$work/$manifest.minisig" --dist "$work" \
  || reject "a bridge bundle does not match the signed manifest"
echo "signed manifest verified for $tag: ${bundles[*]}"

# 4. Build provenance from this repository's release workflow.
# gh accepts one --source-ref per call, so try each allowed release ref.
attested_from() {
  local ref
  for ref in "refs/tags/$tag" "refs/heads/$default_branch"; do
    if gh attestation verify "$work/$1" --repo "$repo" --signer-workflow "$signer" \
      --source-ref "$ref" > /dev/null 2>> "$work/attest.err"; then
      echo "$ref"; return 0
    fi
  done
  return 1
}
for name in "$manifest" "${bundles[@]}"; do
  if ! ref="$(attested_from "$name")"; then
    cat "$work/attest.err" >&2
    reject "$name has no build-provenance attestation from $signer on refs/tags/$tag or refs/heads/$default_branch"
  fi
  echo "attestation verified: $name (built from $ref)"
done

# 5. GitHub's own immutability record.
if [ "$(jq -r '.isImmutable // false' "$release_json")" = "true" ]; then
  gh release verify "$tag" || reject "gh release verify failed"
  for name in "$manifest" "${bundles[@]}"; do
    gh release verify-asset "$tag" "$work/$name" || reject "gh release verify-asset failed for $name"
  done
  echo "$tag is an immutable release; release attestation verified"
else
  echo "::warning::$tag is not an immutable release; enable 'Release immutability' in the repository settings (docs/release-signing.md)"
fi
