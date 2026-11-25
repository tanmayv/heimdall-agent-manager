#!/usr/bin/env bash
# Build the binaries of the conversion e2e (P2-7, tests/e2e/conversion_e2e.mjs) on Linux/macOS.
# Run inside the flake shell: nix develop -c scripts/supervisor/conversion-build.sh <out-dir> [version]
# Produces <out>/bundle/bin/{ham-bridge,ham-ctl,ham-pty-host,ham-launcher,ham-supervisor}
# (a supervisor-capable bundle at a TEST version newer than every legacy release, with the
# test-only signing key trusted by the test builds) and <out>/tools/conversion_release_server.
# ham-pty-host is the release build (nix build .#release-ham-pty-host). The Windows
# equivalent is scripts/windows/build.ps1 -ExtraOdinFlags in conversion-e2e.yml.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
out=${1:?usage: conversion-build.sh <out-dir> [version]}
version=${2:-0.9.0}
mkdir -p "$out/bundle/bin" "$out/tools"
cd "$root"
curl_version=$(python3 -c 'import json; print(json.load(open("nix/libcurl-pin.json"))["curl"]["version"])')
key=$(sed -n 2p src/supervisor/testdata/e2e-test-key.pub)
common=(-collection:odin_test="$root/src" -define:HAM_APP_VERSION="$version" -define:HAM_CURL_VERSION="$curl_version"
  -define:HEIMDALL_SUPERVISOR_TEST=true -define:HEIMDALL_TEST_PINNED_KEY="$key")
for pair in bridge:ham-bridge ctl:ham-ctl launcher:ham-launcher supervisor:ham-supervisor; do
  odin build "src/${pair%%:*}" "${common[@]}" -out:"$out/bundle/bin/${pair##*:}"
done
odin build tools/conversion_release_server -collection:odin_test="$root/src" -vet -strict-style -out:"$out/tools/conversion_release_server"
pty=$(nix build .#release-ham-pty-host --print-out-paths --no-link)
cp "$pty/bin/ham-pty-host" "$out/bundle/bin/ham-pty-host"
chmod +x "$out"/bundle/bin/*
# A release build must not carry the hooks or the test key (they exist only in -define:HEIMDALL_SUPERVISOR_TEST builds).
odin build src/bridge -collection:odin_test="$root/src" -define:HAM_APP_VERSION="$version" -define:HAM_CURL_VERSION="$curl_version" -out:"$out/ham-bridge-default"
if grep -aqF HEIMDALL_CONVERT_KILL_AFTER "$out/ham-bridge-default" || grep -aqF "$key" "$out/ham-bridge-default"; then
  echo "FAIL: a default ham-bridge build carries the conversion test hooks or the test key" >&2; exit 1
fi
grep -aqF HEIMDALL_CONVERT_KILL_AFTER "$out/bundle/bin/ham-bridge" || { echo "FAIL: the test ham-bridge lacks the hooks (check is vacuous)" >&2; exit 1; }
rm -f "$out/ham-bridge-default"
echo "built bundle $version in $out/bundle"
