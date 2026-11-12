#!/usr/bin/env bash
# Run Odin from any working directory with Heimdall's collection and curl pin.
set -euo pipefail

usage() {
  echo 'Usage: scripts/dev-odin.sh {check|test|run|build-debug} <package-directory> [Odin flags / -- program args]' >&2
}
if [[ $# -lt 2 ]]; then usage; exit 2; fi
action=$1
case "$action" in check|test|run|build-debug) ;; *) usage; exit 2 ;; esac
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
case "$2" in /*) package=$2 ;; *) package="$root/$2" ;; esac
if [[ ! -d "$package" ]]; then echo "Package does not exist: $package" >&2; exit 2; fi
package=$(cd -- "$package" && pwd -P)
case "$package/" in "$root/"*) ;; *) echo 'Package must be inside this checkout.' >&2; exit 2 ;; esac
shift 2
cd -- "$root"
curl_version=$(python3 -c 'import json; print(json.load(open("nix/libcurl-pin.json"))["curl"]["version"])')
flags=("-collection:odin_test=$root/src" "-define:HAM_CURL_VERSION=$curl_version")
if [[ "$action" == check ]]; then
  exec odin check "$package" "${flags[@]}" -no-entry-point "$@"
fi

# Keep executable output out of /tmp and out of the checkout. Each invocation
# gets its own directory, so editors/worktrees can run tests concurrently.
mkdir -p "$HOME/.cache/heimdall-tests"
build_dir=$(mktemp -d "$HOME/.cache/heimdall-tests/editor-XXXXXX")
output="$build_dir/$(basename -- "$package")"
if [[ "$action" == build-debug ]]; then
  # Print only the executable path to stdout for editor/debugger integration.
  odin build "$package" "${flags[@]}" "-out:$output" -debug -o:none "$@" >&2
  printf '%s\n' "$output"
else
  exec odin "$action" "$package" "${flags[@]}" "-out:$output" "$@"
fi
