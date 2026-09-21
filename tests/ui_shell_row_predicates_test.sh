#!/usr/bin/env bash
# Row-level predicate truth table for the shells panel (XM-9, covering XM-7/XM-8 too).
#
# Why this exists: what a shell row RENDERS is decided by four small predicates over
# (status x server_port). They are easy to read, believe, and get wrong — XM-8 shipped
# a render gap that survived review precisely because the predicate looked right in
# isolation. This runs them as real code, imported from the shipping component, over
# every case in the matrix, and asserts the cases each change actually claims.
#
# It is NOT a renderer test: it makes no DOM and proves nothing about layout. It proves
# the decisions feeding the layout. For the layout, screenshot the panel (see the XM-9
# handoff for the firefox --screenshot recipe).
#
# Usage: tests/ui_shell_row_predicates_test.sh
# Requires: npm install already done (esbuild + node come from node_modules).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

OUT="$(mktemp -d -t shell-predicates-XXXX)"
trap 'rm -rf "$OUT"' EXIT

# Bundle the real component. @ui is a tsconfig path alias that esbuild does not read,
# so it is passed explicitly; import.meta.env is Vite's and is absent under node.
./node_modules/.bin/esbuild src/ui/components/shells/ShellsPanel.tsx \
  --bundle --format=esm --platform=node --jsx=automatic \
  --alias:@ui=./src/ui/components/ui/index.ts \
  --define:import.meta.env='{"DEV":false,"PROD":true,"MODE":"production"}' \
  --outfile="$OUT/panel.mjs" --log-level=error

cp tests/ui/shell_row_predicates.mjs "$OUT/run.mjs"
node "$OUT/run.mjs"
