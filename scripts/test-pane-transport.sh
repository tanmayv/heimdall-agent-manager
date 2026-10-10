#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
task_test_dir="$(mktemp -d)"
trap 'rm -rf "$task_test_dir"' EXIT
build_flags=()
if [[ -n "${ODIN_EXTRA_LINKER_FLAGS:-}" ]]; then
  build_flags+=("-extra-linker-flags:${ODIN_EXTRA_LINKER_FLAGS}")
fi
"${ODIN_BIN:-odin}" build tests/fixtures/pane_transport_server.odin -file \
  -collection:odin_test=src "${build_flags[@]}" -out:"$task_test_dir/pane-server"
HEIMDALL_PANE_TEST_SERVER="$task_test_dir/pane-server" \
  node --test tests/ui_pane_transport_e2e_test.ts tests/ui_pane_delivery_queue_test.ts
