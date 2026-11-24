#!/usr/bin/env bash
# Build the supervisor e2e binaries and run src/supervisor/e2e (T13b) on Linux/macOS.
# Run inside the flake shell: nix develop -c scripts/supervisor/e2e.sh [out-dir]
# E2E_TEST_NAMES=e2e.test_a,e2e.test_b runs only those tests (ODIN_TEST_NAMES).
# The Windows equivalent is the pwsh step in .github/workflows/supervisor-e2e.yml.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
out=${1:-"$HOME/.cache/heimdall-tests/supervisor-e2e"}
mkdir -p "$out"
cd "$root"
curl_version=$(python3 -c 'import json; print(json.load(open("nix/libcurl-pin.json"))["curl"]["version"])')
key=$(sed -n 2p src/supervisor/testdata/e2e-test-key.pub)
common=(-collection:odin_test="$root/src")
odin build src/launcher "${common[@]}" -out:"$out/ham-launcher"
odin build src/supervisor "${common[@]}" -define:HAM_CURL_VERSION="$curl_version" \
  -define:HEIMDALL_SUPERVISOR_TEST=true -define:HEIMDALL_TEST_PINNED_KEY="$key" -out:"$out/ham-supervisor"
# A default build (no test defines, as the release workflow builds it) must embed only the
# pinned release keys: the e2e test key must not be in it; the test build must carry it.
odin build src/supervisor "${common[@]}" -define:HAM_CURL_VERSION="$curl_version" -out:"$out/ham-supervisor-default"
if grep -aqF "$key" "$out/ham-supervisor-default"; then
  echo "FAIL: a default ham-supervisor build contains the e2e test key" >&2; exit 1
fi
if ! grep -aqF "$key" "$out/ham-supervisor"; then
  echo "FAIL: the test ham-supervisor build lacks the e2e test key (check is vacuous)" >&2; exit 1
fi
echo "key check: default build has no test key; test build has it"
odin build src/supervisor/testdata/fakebridge "${common[@]}" -vet -strict-style -out:"$out/fakebridge"
names=()
if [ -n "${E2E_TEST_NAMES:-}" ]; then names=(-define:ODIN_TEST_NAMES="$E2E_TEST_NAMES"); fi
HEIMDALL_E2E_BIN_DIR="$out" odin test src/supervisor/e2e "${common[@]}" -vet -strict-style \
  -define:ODIN_TEST_THREADS=1 "${names[@]}" -out:"$out/supervisor-e2e"
