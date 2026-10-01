#!/usr/bin/env bash
# REQ-SHELL-6 AC3 — runs the REAL wsInvalidation handler over the hub's REAL frame
# shapes, asserting that a status change actually reaches the caches now that every
# shell poller is gone. See tests/ui/shell_req6_push.mjs for why executing the handler
# is the point rather than grepping for the case label.
#
# Usage: tests/ui_shell_req6_push_test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

OUT="$(mktemp -d -t shell-req6-push-XXXX)"
trap 'rm -rf "$OUT"' EXIT

./node_modules/.bin/esbuild src/ui/api/wsInvalidation.ts \
  --bundle --format=esm --platform=node --jsx=automatic \
  --tsconfig=tsconfig.renderer.json \
  --define:import.meta.env='{"DEV":false,"PROD":true,"MODE":"production"}' \
  --outfile="$OUT/ws.mjs" --log-level=error

cp tests/ui/shell_req6_push.mjs "$OUT/run.mjs"
node --test "$OUT/run.mjs"
