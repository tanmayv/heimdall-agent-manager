#!/usr/bin/env bash
# REQ-SHELL-6 predicate truth tables, run as REAL CODE from the shipping modules.
#
# Bundles shellModel.ts and ShellOutputStates.tsx with esbuild, then runs the assertions
# under node --test. Testing the real exports rather than regexing the source is the
# point: these predicates decide what the user SEES (is a run pinned, may a terminal
# server appear, is a kill offered as durable), and a regex cannot evaluate them.
#
# NOTE ON --tsconfig, which is load-bearing: the older
# tests/ui_shell_row_predicates_test.sh passes `--alias:@ui=...` instead, and that is
# BROKEN at HEAD — an alias maps the bare specifier '@ui' but not subpaths, so
# '@ui/hooks/useViewport' resolves to '<index.ts>/hooks/useViewport' and the bundle
# fails before a single assertion runs. Handing esbuild the real tsconfig lets it read
# the `paths` map ('@ui' AND '@ui/*') and both forms resolve. Repointing that older test
# is REQ-SHELL-22.
#
# Usage: tests/ui_shell_req6_predicates_test.sh
# Requires: npm install (esbuild + node come from node_modules).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

OUT="$(mktemp -d -t shell-req6-XXXX)"
trap 'rm -rf "$OUT"' EXIT

bundle() {
  ./node_modules/.bin/esbuild "$1" \
    --bundle --format=esm --platform=node --jsx=automatic \
    --tsconfig=tsconfig.renderer.json \
    --define:import.meta.env='{"DEV":false,"PROD":true,"MODE":"production"}' \
    --outfile="$2" --log-level=error
}

bundle src/ui/components/shells/shellModel.ts        "$OUT/model.mjs"
bundle src/ui/components/shells/ShellOutputStates.tsx "$OUT/states.mjs"

cp tests/ui/shell_req6_predicates.mjs "$OUT/run.mjs"
node --test "$OUT/run.mjs"
