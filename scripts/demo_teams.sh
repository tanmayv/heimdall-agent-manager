#!/usr/bin/env bash
set -euo pipefail

: "${HAM_TOKEN:?set HAM_TOKEN to an agent token accepted by the test daemon}"
DAEMON_URL="${DAEMON_URL:-http://127.0.0.1:49422}"
HAM_CTL="${HAM_CTL:-$(command -v bc-odinctl || true)}"
if [[ -z "$HAM_CTL" ]]; then
  for candidate in ./result/bin/bc-odinctl ./result-1/bin/bc-odinctl ./result-2/bin/bc-odinctl; do
    if [[ -x "$candidate" ]]; then HAM_CTL="$candidate"; break; fi
  done
fi
if [[ -z "$HAM_CTL" ]]; then
  echo "bc-odinctl not found; set HAM_CTL or run nix build .#bc-odinctl" >&2
  exit 1
fi
CONFIG="${CONFIG:-./config-test.toml}"
CHAIN_ID="demo-teams-${RANDOM}-${RANDOM}"
PROJECT_ID="demo-project"

printf 'Creating chain %s with kind=coding...\n' "$CHAIN_ID"
"$HAM_CTL" --config "$CONFIG" --daemon-url "$DAEMON_URL" task-chains create \
  --token "$HAM_TOKEN" \
  --chain-id "$CHAIN_ID" \
  --title "Teams demo" \
  --project "$PROJECT_ID" \
  --kind coding \
  --coordinator demo-coordinator \
  --reviewer demo-reviewer \
  --json || true

TEAM_ID="team-${CHAIN_ID}"
printf '\nInspecting auto-created team %s...\n' "$TEAM_ID"
"$HAM_CTL" --config "$CONFIG" --daemon-url "$DAEMON_URL" teams show --team "$TEAM_ID"

printf '\nTeam members...\n'
"$HAM_CTL" --config "$CONFIG" --daemon-url "$DAEMON_URL" teams show-members --team "$TEAM_ID"

printf '\nFocus chain...\n'
"$HAM_CTL" --config "$CONFIG" --daemon-url "$DAEMON_URL" chains focus --chain "$CHAIN_ID"
