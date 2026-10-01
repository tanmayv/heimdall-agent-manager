#!/usr/bin/env bash
# Preview predicate truth table for the shells UI (XM-9, covering XM-7/XM-8 too).
#
# Why this exists: what the preview affordance RENDERS is decided by three small
# predicates over (status x server_port). They are easy to read, believe, and get wrong —
# XM-8 shipped a render gap that survived review precisely because the predicate looked
# right in isolation. This runs them as real code over every case in the matrix, and
# asserts the cases each change actually claims.
#
# WHAT IT IMPORTS, AND WHY THAT CHANGED (REQ-SHELL-22): the predicates come from
# src/ui/components/shells/shellModel.ts — canPreview, hasPreviewAffordance and
# previewUnavailableReason — which is the code that actually SHIPS: `PreviewCard` in
# ShellDetail.tsx (:574-576) calls all three to decide whether the preview card appears,
# whether it is enabled, and what reason it gives. This test previously bundled
# ShellsPanel.tsx, which despite the header's claim of "the shipping component" was never
# mounted by anything; the truth table was covering dead code while the live predicates
# had none. ShellsPanel.tsx was deleted and this now points at the live ones.
#
# It is NOT a renderer test: it makes no DOM and proves nothing about layout. It proves
# the decisions feeding the layout. For the layout, screenshot the UI (see the XM-9
# handoff for the firefox --screenshot recipe).
#
# Usage: tests/ui_shell_row_predicates_test.sh
# Requires: npm install already done (esbuild + node come from node_modules).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

OUT="$(mktemp -d -t shell-predicates-XXXX)"
trap 'rm -rf "$OUT"' EXIT

# Bundle the real module. No --alias:@ui is needed: shellModel's only `@ui` import is
# `import type { IconName, Tone }` (:50), a bare type-only specifier that esbuild erases,
# so nothing resolves through the alias. The old --alias:@ui=<a single .ts FILE> was in
# fact broken — esbuild remaps subpaths textually, so `@ui/hooks/useViewport` became
# `<that file>/hooks/useViewport` and failed to resolve; pointing at the live module
# removes the need for it rather than papering over it.
# import.meta.env is Vite's and is absent under node.
./node_modules/.bin/esbuild src/ui/components/shells/shellModel.ts \
  --bundle --format=esm --platform=node --jsx=automatic \
  --define:import.meta.env='{"DEV":false,"PROD":true,"MODE":"production"}' \
  --outfile="$OUT/panel.mjs" --log-level=error

cp tests/ui/shell_row_predicates.mjs "$OUT/run.mjs"
node "$OUT/run.mjs"
