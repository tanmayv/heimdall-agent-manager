#!/usr/bin/env bash
# Scale H load harness for the hub task engine (docs/reference/scale-harness.md).
#
# Opt-in: the harness test is only compiled in with -define:HEIMDALL_SCALE_HARNESS=true,
# so default `odin test` runs of src/hub/service/taskv2 never execute it.
#
#   scripts/scale-harness.sh [--rev <git-rev>] [--label <name>] [--out <file.json>]
#
# --rev runs the harness against another commit: a detached temporary worktree
# at <rev> gets this checkout's harness files (and the opt-in lock profile, if
# the commit lacks it) copied in, so the same scenario measures old code.
# Sizes come from the environment (defaults: the full 100 chains x 1,000 tasks):
#   HEIMDALL_SCALE_CHAINS HEIMDALL_SCALE_TASKS HEIMDALL_SCALE_THREADS HEIMDALL_SCALE_OPS
#   HEIMDALL_SCALE_SERIAL_OPS HEIMDALL_SCALE_BOOT (comma list of done-task counts)
#   HEIMDALL_SCALE_DB_DIR (default ~/.cache/heimdall-scale; "memory" for :memory:)
# Run inside `nix develop` (pinned Odin).
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
rev="" label="" out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rev) rev=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

src_root=$root
cleanup() { :; }
if [[ -n "$rev" ]]; then
  wt=$(mktemp -d "$HOME/.cache/heimdall-scale-wt-XXXXXX")
  git -C "$root" worktree add --detach "$wt" "$rev" >/dev/null
  cleanup() { git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true; }
  trap cleanup EXIT
  # The harness, plus the opt-in lock profile when the commit predates it:
  # the commit that added lock_profile.odin is applied (3-way) to the worktree.
  if [[ ! -f "$wt/src/hub/platform/dbtelemetry/lock_profile.odin" ]]; then
    profile_commit=$(git -C "$root" log --diff-filter=A --format=%H -1 -- src/hub/platform/dbtelemetry/lock_profile.odin)
    git -C "$root" show "$profile_commit" | git -C "$wt" apply --3way
  fi
  cp "$root/src/hub/service/taskv2/scale_harness_test.odin" "$wt/src/hub/service/taskv2/"
  src_root=$wt
  [[ -n "$label" ]] || label=$(git -C "$root" rev-parse --short "$rev")
fi
[[ -n "$label" ]] || label=$(git -C "$root" rev-parse --short HEAD)

db_dir=${HEIMDALL_SCALE_DB_DIR:-$HOME/.cache/heimdall-scale}
if [[ "$db_dir" == memory ]]; then db_dir=""; else mkdir -p "$db_dir"; fi
mkdir -p "$HOME/.cache/heimdall-tests"
bin="$HOME/.cache/heimdall-tests/scale-harness-$label-$$"
[[ -n "$out" ]] || out="$HOME/.cache/heimdall-scale/result-$label.json"
mkdir -p "$(dirname -- "$out")"

curl_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["curl"]["version"])' "$src_root/nix/libcurl-pin.json")
cd -- "$src_root"
HEIMDALL_SCALE_LABEL=$label HEIMDALL_SCALE_DB_DIR=$db_dir HEIMDALL_SCALE_OUT=$out \
odin test src/hub/service/taskv2 \
  "-collection:odin_test=$src_root/src" "-define:HAM_CURL_VERSION=$curl_version" \
  -define:HEIMDALL_SCALE_HARNESS=true -define:ODIN_TEST_NAMES=taskv2.test_scale_harness \
  -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false \
  ${HEIMDALL_SCALE_ODIN_FLAGS:-} "-out:$bin"
rm -f "$bin"
echo "scale harness result: $out"
