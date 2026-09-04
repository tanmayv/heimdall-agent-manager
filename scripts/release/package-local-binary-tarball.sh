#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: package-local-binary-tarball.sh <target> <version> <out-dir> <ham-bridge-out> <ham-wrapper-out> <ham-ctl-out> [ham-pty-host-out]

Creates dist tarball: <out-dir>/heimdall-local-<target>.tar.gz
Tarball root contains: bin/ham-bridge, bin/ham-wrapper, bin/ham-ctl, README.md, LICENSE, METADATA.json
When the optional <ham-pty-host-out> is given, bin/ham-pty-host is also shipped
(self-contained; PTYH-4).
USAGE
}

if [ "$#" -lt 6 ] || [ "$#" -gt 7 ]; then
  usage
  exit 2
fi

target="$1"
version="$2"
out_dir="$3"
ham_bridge_out="$4"
ham_wrapper_out="$5"
ham_ctl_out="$6"
ham_pty_host_out="${7:-}"

case "$target" in
  darwin-arm64|darwin-amd64|linux-amd64|linux-arm64) ;;
  *) echo "unsupported release target: $target" >&2; exit 2 ;;
esac

for spec in \
  "$ham_bridge_out/bin/ham-bridge" \
  "$ham_wrapper_out/bin/ham-wrapper" \
  "$ham_ctl_out/bin/ham-ctl" \
  "README.md" \
  "LICENSE"
do
  if [ ! -f "$spec" ]; then
    echo "missing required release input: $spec" >&2
    exit 1
  fi
done

mkdir -p "$out_dir"
work_dir="$(mktemp -d)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

stage="$work_dir/stage"
mkdir -p "$stage/bin"
install -m 0755 "$ham_bridge_out/bin/ham-bridge" "$stage/bin/ham-bridge"
if [ -f "$ham_bridge_out/bin/openssl" ]; then
  install -m 0755 "$ham_bridge_out/bin/openssl" "$stage/bin/openssl"
fi
install -m 0755 "$ham_wrapper_out/bin/ham-wrapper" "$stage/bin/ham-wrapper"
install -m 0755 "$ham_ctl_out/bin/ham-ctl" "$stage/bin/ham-ctl"
# PTYH-4: ship the self-contained PTY host binary when its Nix output is
# provided. Optional so existing 6-arg callers keep working unchanged.
ham_pty_host_shipped=false
if [ -n "$ham_pty_host_out" ]; then
  if [ ! -f "$ham_pty_host_out/bin/ham-pty-host" ]; then
    echo "missing required release input: $ham_pty_host_out/bin/ham-pty-host" >&2
    exit 1
  fi
  install -m 0755 "$ham_pty_host_out/bin/ham-pty-host" "$stage/bin/ham-pty-host"
  ham_pty_host_shipped=true
fi
install -m 0644 README.md "$stage/README.md"
install -m 0644 LICENSE "$stage/LICENSE"

commit="${GITHUB_SHA:-$(git rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}"
built_at="${SOURCE_DATE_EPOCH:-}"
if [ -n "$built_at" ]; then
  built_at_iso="$(date -u -r "$built_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$built_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
else
  built_at_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
if [ "$ham_pty_host_shipped" = true ]; then
  binaries_json='["ham-bridge", "ham-wrapper", "ham-ctl", "ham-pty-host"]'
else
  binaries_json='["ham-bridge", "ham-wrapper", "ham-ctl"]'
fi
cat > "$stage/METADATA.json" <<META
{
  "product": "heimdall-local",
  "version": "$version",
  "target": "$target",
  "commit": "$commit",
  "built_at": "$built_at_iso",
  "binaries": $binaries_json,
  "tls_dependency": "OpenSSL s_client via PATH or bundled bin/openssl when present"
}
META

tarball="$out_dir/heimdall-local-$target.tar.gz"
tar -C "$stage" -czf "$tarball" bin README.md LICENSE METADATA.json

required_entries=(
  "bin/ham-bridge"
  "bin/ham-wrapper"
  "bin/ham-ctl"
  "README.md"
  "LICENSE"
)
if [ "$ham_pty_host_shipped" = true ]; then
  required_entries+=("bin/ham-pty-host")
fi
for entry in "${required_entries[@]}"; do
  if ! tar -tzf "$tarball" | grep -Fxq "$entry"; then
    echo "tarball missing required entry: $entry" >&2
    exit 1
  fi
done

printf '%s\n' "$tarball"
