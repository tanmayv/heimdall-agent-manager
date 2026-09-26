#!/usr/bin/env bash
# REQ-DIST-5: one-line bootstrap installer for non-hub heimdall nodes.
# Verifies the release checksum BEFORE extracting anything (see fail-fast below).
set -euo pipefail

GITHUB_REPO="tanmayv/heimdall-agent-manager"

usage() {
  cat >&2 <<'USAGE'
usage: install.sh [--version <tag>] [--hub <url>] [--dry-run]

Installs prebuilt heimdall binaries (heimdall, ham-bridge, ham-pty-host,
ham-ctl), wires PATH, and registers a user-level heimdall-bridge service.

  --version <tag>  install release <tag> instead of the latest GitHub release
  --hub <url>      download <url>/heimdall-local-<target>.tar.gz and
                   <url>/SHA256SUMS; also baked into the service template
                   and enroll instructions (self-hosted hub mirror)
  --dry-run        print every planned action without writing anything

Platforms: Linux (x86_64, aarch64/arm64), macOS (Intel, Apple Silicon).
USAGE
}

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

version=""
hub_url=""
dry_run=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || fail "--version requires a value (e.g. v0.1.0)"
      version="$2"; shift 2 ;;
    --hub)
      [ "$#" -ge 2 ] || fail "--hub requires a url"
      hub_url="${2%/}"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; fail "unknown argument: $1" ;;
  esac
done

# --- platform detection -----------------------------------------------------
uname_s="$(uname -s)"
uname_m="$(uname -m)"
case "$uname_m" in
  x86_64|amd64) arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) fail "unsupported architecture '$uname_m' (need x86_64 or arm64/aarch64)" ;;
esac
case "$uname_s" in
  Linux) os="linux" ;;
  Darwin) os="darwin" ;;
  *) fail "unsupported operating system '$uname_s' (need Linux or macOS)" ;;
esac
target="$os-$arch"

if [ "$(id -u)" -eq 0 ]; then
  install_dir="/usr/local/bin"
else
  install_dir="$HOME/.local/bin"
fi

# --- release URL resolution -------------------------------------------------
resolve_latest_tag() {
  curl -fsSL --connect-timeout 15 --max-time 30 \
    "https://api.github.com/repos/$GITHUB_REPO/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

if [ -n "$hub_url" ]; then
  base_url="$hub_url"
  tarball_name="heimdall-local-$target.tar.gz"
  effective_version="${version:-custom-hub-release}"
elif [ -n "$version" ]; then
  base_url="https://github.com/$GITHUB_REPO/releases/download/$version"
  tarball_name="heimdall-local-$target-$version.tar.gz"
  effective_version="$version"
else
  if "$dry_run"; then
    # Best effort only: a dry run must stay usable on offline machines.
    effective_version="$(resolve_latest_tag || true)"
    [ -n "$effective_version" ] || effective_version="<latest-release-tag>"
  else
    if ! effective_version="$(resolve_latest_tag)" || [ -z "$effective_version" ]; then
      fail "could not resolve the latest GitHub release (api.github.com unreachable?); pass --version <tag> or --hub <url>"
    fi
  fi
  base_url="https://github.com/$GITHUB_REPO/releases/download/$effective_version"
  tarball_name="heimdall-local-$target-$effective_version.tar.gz"
fi
sums_name="SHA256SUMS"
tarball_url="$base_url/$tarball_name"
sums_url="$base_url/$sums_name"

# --- service templates (mirrors SELF_HOSTING.md sections 2.8 and 2.9) -------
service_hub_url() { [ -n "$hub_url" ] && printf '%s' "$hub_url" || printf '%s' "https://hub.example.com"; }

render_systemd_unit() {
  cat <<UNIT
[Unit]
Description=Heimdall Bridge
After=network-online.target

[Service]
Type=simple
ExecStart=$install_dir/ham-bridge \\
    --hub $(service_hub_url) \\
    --bridge-token-file %h/.config/heimdall/bridge-token \\
    --port 49323 \\
    --local-endpoint-port 49324 \\
    --local-run-dir /tmp/heimdall-bridge-local
Environment=HEIMDALL_HAM_PTY_HOST_BIN=$install_dir/ham-pty-host
Environment=HEIMDALL_BRIDGE_PTY_HOST=true
Environment=HEIMDALL_HAM_CTL_BIN=$install_dir/ham-ctl
Restart=on-failure
RestartSec=5s
KillMode=process

[Install]
WantedBy=default.target
UNIT
}

render_launchd_plist() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>works.earendil.heimdall-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>$install_dir/ham-bridge</string>
    <string>--hub</string>
    <string>$(service_hub_url)</string>
    <string>--bridge-token-file</string>
    <string>$HOME/.config/heimdall/bridge-token</string>
    <string>--port</string>
    <string>49323</string>
    <string>--local-endpoint-port</string>
    <string>49324</string>
    <string>--local-run-dir</string>
    <string>/tmp/heimdall-bridge-local</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HEIMDALL_HAM_PTY_HOST_BIN</key>
    <string>$install_dir/ham-pty-host</string>
    <key>HEIMDALL_BRIDGE_PTY_HOST</key>
    <string>true</string>
    <key>HEIMDALL_HAM_CTL_BIN</key>
    <string>$install_dir/ham-ctl</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>Crashed</key>
    <true/>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/heimdall-logs/heimdall-bridge.err.log</string>
</dict>
</plist>
PLIST
}

if [ "$os" = "linux" ]; then
  service_dir="$HOME/.config/systemd/user"
  service_file="$service_dir/heimdall-bridge.service"
  service_label="heimdall-bridge"
else
  service_dir="$HOME/Library/LaunchAgents"
  service_file="$service_dir/works.earendil.heimdall-bridge.plist"
  service_label="works.earendil.heimdall-bridge"
fi

# --- onboarding text ----------------------------------------------------------
print_onboarding() {
  hub_display="$(service_hub_url)"
  hub_note=""
  if [ -z "$hub_url" ]; then
    hub_note="  (replace the --hub URL with your hub, or re-run: install.sh --hub <url>)"
  fi
  cat <<EOF

Installed heimdall $effective_version for $target.

Next steps:

1. On the HUB, create a one-time enrollment token:
     ham-ctl bridge enroll-token --new

2. On THIS machine, enroll this node:
     heimdall enroll hbe_... --hub $hub_display$hub_note
   Underlying engine (compatibility): ham-bridge enroll --hub $hub_display --enrollment-token hbe_... --bridge-token-file ~/.config/heimdall/bridge-token

3. Start the bridge service:
EOF
  if [ "$os" = "linux" ]; then
    cat <<'EOF'
     systemctl --user enable --now heimdall-bridge
     systemctl --user status heimdall-bridge
EOF
  else
    cat <<'EOF'
     launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/works.earendil.heimdall-bridge.plist
     launchctl kickstart -k gui/$(id -u)/works.earendil.heimdall-bridge
EOF
  fi
  cat <<EOF

Service file: $service_file (registered but not started; enrollment comes first)
Logs: macOS /tmp/heimdall-logs/heimdall-bridge.*.log; Linux 'journalctl --user -u heimdall-bridge -f'
EOF
}

# --- dry run ------------------------------------------------------------------
if "$dry_run"; then
  say "platform: $os/$arch (release target $target)"
  say "release: $effective_version"
  say "would download: $tarball_url"
  say "would download: $sums_url"
  say "would verify SHA-256 of $tarball_name against SHA256SUMS before extracting"
  say "would install bin/heimdall bin/ham-bridge bin/ham-pty-host bin/ham-ctl (and bin/openssl if bundled) to $install_dir"
  case ":$PATH:" in
    *":$install_dir:"*) say "$install_dir is already on PATH" ;;
    *) say "would add $install_dir to PATH in ~/.bashrc / ~/.zshrc (idempotent)" ;;
  esac
  say "would write service file $service_file with contents:"
  if [ "$os" = "linux" ]; then render_systemd_unit; else render_launchd_plist; fi
  print_onboarding
  exit 0
fi

# --- download -----------------------------------------------------------------
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
  || fail "need curl or wget to download the release bundle"

download() {
  url="$1"; out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "$out" "$url"
  else
    wget -O "$out" "$url"
  fi
}

say "downloading $tarball_url"
work_dir="$(mktemp -d)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

download "$tarball_url" "$work_dir/$tarball_name"
say "downloading $sums_url"
download "$sums_url" "$work_dir/$sums_name"

# --- verify BEFORE extracting -------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "need sha256sum or shasum -a 256 to verify the download"
  fi
}

expected="$(awk -v f="$tarball_name" '$2 == f {print $1; exit}' "$work_dir/$sums_name")"
[ -n "$expected" ] || fail "$sums_name has no entry for $tarball_name"
actual="$(sha256_of "$work_dir/$tarball_name")"
# Fail-closed: a corrupt or hostile tarball must never reach the filesystem
# as an installed binary, so nothing is extracted until the checksum matches.
if [ "$actual" != "$expected" ]; then
  fail "SHA-256 mismatch for $tarball_name (expected $expected, got $actual); aborting before extraction"
fi
say "checksum verified ($actual)"

# --- extract and install ------------------------------------------------------
tar -xzf "$work_dir/$tarball_name" -C "$work_dir"
bundle_bin="$work_dir/bin"
binaries="heimdall ham-bridge ham-pty-host ham-ctl"
for b in $binaries; do
  [ -f "$bundle_bin/$b" ] || fail "release bundle is missing bin/$b; refusing to install an incomplete bundle"
done

say "installing to $install_dir"
mkdir -p "$install_dir"
for b in $binaries; do
  install -m 0755 "$bundle_bin/$b" "$install_dir/$b"
  say "installed $install_dir/$b"
done
if [ -f "$bundle_bin/openssl" ]; then
  install -m 0755 "$bundle_bin/openssl" "$install_dir/openssl"
  say "installed bundled $install_dir/openssl"
fi

# --- PATH ---------------------------------------------------------------------
case ":$PATH:" in
  *":$install_dir:"*)
    say "$install_dir is already on PATH" ;;
  *)
    path_line="export PATH=\"$install_dir:\$PATH\""
    touched=false
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      if [ -f "$rc" ]; then
        if grep -Fqx "$path_line" "$rc" 2>/dev/null; then
          say "$rc already adds $install_dir to PATH"
        else
          printf '\n# Added by heimdall install.sh\n%s\n' "$path_line" >> "$rc"
          say "added $install_dir to PATH in $rc"
        fi
        touched=true
      fi
    done
    if ! "$touched"; then
      case "${SHELL:-}" in
        */zsh) rc="$HOME/.zshrc" ;;
        *) rc="$HOME/.bashrc" ;;
      esac
      printf '\n# Added by heimdall install.sh\n%s\n' "$path_line" >> "$rc"
      say "created $rc adding $install_dir to PATH"
    fi
    say "open a new shell (or 'source' the rc file) so PATH picks up $install_dir"
    ;;
esac

# --- service file -------------------------------------------------------------
mkdir -p "$HOME/.config/heimdall"
say "writing service file $service_file"
mkdir -p "$service_dir"
if [ "$os" = "linux" ]; then
  render_systemd_unit > "$service_file"
else
  render_launchd_plist > "$service_file"
fi
chmod 0644 "$service_file"
if [ "$os" = "linux" ] && command -v systemctl >/dev/null 2>&1; then
  # Best effort: user systemd may not be available in every context (root,
  # containers); the printed instructions cover the manual path.
  systemctl --user daemon-reload 2>/dev/null \
    && say "systemd user unit registered (not started)" \
    || warn "could not run 'systemctl --user daemon-reload'; run it manually before starting the service"
fi

print_onboarding
