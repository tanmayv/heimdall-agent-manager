#!/usr/bin/env bash
# Fails when a release consumer disagrees with src/lib/releaserepo or still
# points release downloads/lookups at the source repository.
set -euo pipefail
cd "$(dirname "$0")/.."
owner=$(sed -n 's/^OWNER :: "\(.*\)"/\1/p' src/lib/releaserepo/releaserepo.odin)
name=$(sed -n 's/^NAME :: "\(.*\)"/\1/p' src/lib/releaserepo/releaserepo.odin)
want="$owner/$name"
rc=0
grep -q "^REPO=$want\$" scripts/install.sh || { echo "scripts/install.sh REPO != $want"; rc=1; }
grep -q "^\$HeimdallRepo = '$want'" scripts/install.ps1 || { echo "scripts/install.ps1 HeimdallRepo != $want"; rc=1; }
grep -q "^  owner: $owner\$" electron-builder.yml && grep -q "^  repo: $name\$" electron-builder.yml || { echo "electron-builder.yml publish != $want"; rc=1; }
if grep -rn --include='*.odin' --include='*.sh' --include='*.ps1' --include='*.yml' --include='*.nix' \
     -E 'releases/(download|latest|tags)|/releases"' src scripts electron-builder.yml nix 2>/dev/null | grep -v _test.odin | grep 'heimdall-agent-manager'; then
  echo "release download/lookup still uses the source repo"; rc=1
fi
exit $rc
