// Package releaserepo names the public GitHub repository that hosts every
// release artifact (bridge bundles, SHA256SUMS, signed release.json, desktop
// update files). The source repository may be private; releases are published
// here (dual-published to the source repo during the migration window).
// Change it here only; scripts/install.{sh,ps1}, electron-builder.yml and
// nix/home-manager.nix carry the same value (checked by scripts/check-release-repo.sh).
package releaserepo

OWNER :: "tanmayv"
NAME :: "heimdall-releases"
REPO :: OWNER + "/" + NAME
