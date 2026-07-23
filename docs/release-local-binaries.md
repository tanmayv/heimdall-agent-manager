# Releasing Heimdall local binaries

This release path publishes the user-owned local runtime binaries used with the Hub rewrite:

- `ham-bridge`
- `ham-wrapper`
- `ham-ctl`

## Targets

The beta release matrix is intentionally small and explicit:

| Target | GitHub runner | Nix system | Tarball |
|---|---|---|---|
| macOS Apple Silicon | `macos-14` | `aarch64-darwin` | `heimdall-local-darwin-arm64.tar.gz` |
| macOS Intel | `macos-15-intel` | `x86_64-darwin` | `heimdall-local-darwin-amd64.tar.gz` |
| Linux x86_64 | `ubuntu-24.04` | `x86_64-linux` | `heimdall-local-linux-amd64.tar.gz` |
| Linux arm64 | `ubuntu-24.04-arm` | `aarch64-linux` | `heimdall-local-linux-arm64.tar.gz` |

Each tarball contains this root layout:

```text
bin/ham-bridge
bin/ham-wrapper
bin/ham-ctl
README.md
LICENSE
METADATA.json
```

`METADATA.json` records the product name, target, version/tag, commit, build timestamp, and binary list.

## Release workflow

Workflow: `.github/workflows/release-local-binaries.yml`

Triggers:

- Push a tag matching `v*` to build all four targets and publish a GitHub Release.
- Run `workflow_dispatch` with `publish_release=false` to dry-run build/package/upload workflow artifacts without creating a GitHub Release.
- Run `workflow_dispatch` with `publish_release=true` to create/update a release for the supplied version.

The workflow uses a clean checkout, installs Nix with flakes enabled, builds `.#ham-bridge`, `.#ham-wrapper`, and `.#ham-ctl`, packages the four target tarballs, verifies required tar entries, and publishes a combined `SHA256SUMS` manifest. Any build, packaging, tar verification, checksum, artifact upload, or release upload failure stops the workflow.

The per-target workflow artifact names include the version/tag, for example `heimdall-local-linux-amd64-v0.1.0-beta.1`. The build/package step first creates the stable required tarball names (`heimdall-local-<target>.tar.gz`) so scripts have deterministic paths. The release job then copies those tarballs to versioned GitHub Release asset names such as `heimdall-local-linux-amd64-v0.1.0-beta.1.tar.gz`; the published `SHA256SUMS` manifest covers the versioned release asset filenames.

Permissions are least-privilege by job:

- Build job: repository contents read-only.
- Release job: contents write, using only the built-in `GITHUB_TOKEN` to create/update the GitHub Release.

## Cutting a release

1. Ensure the release commit has passed normal Hub/Bridge/wrapper validation.
2. Create and push a tag, for example:

   ```bash
   git tag v0.1.0-beta.1
   git push origin v0.1.0-beta.1
   ```

3. Wait for the `Release local binaries` workflow to finish.
4. Verify the GitHub Release contains versioned assets:

   ```text
   heimdall-local-darwin-arm64-v0.1.0-beta.1.tar.gz
   heimdall-local-darwin-amd64-v0.1.0-beta.1.tar.gz
   heimdall-local-linux-amd64-v0.1.0-beta.1.tar.gz
   heimdall-local-linux-arm64-v0.1.0-beta.1.tar.gz
   SHA256SUMS
   ```

5. Verify checksums locally if desired:

   ```bash
   sha256sum -c SHA256SUMS
   ```

## Local package validation

After building the three packages for the current system, the package script can be exercised without publishing:

```bash
mapfile -t paths < <(nix build .#ham-bridge .#ham-wrapper .#ham-ctl --no-link --print-out-paths)
scripts/release/package-local-binary-tarball.sh linux-amd64 dev-local dist "${paths[0]}" "${paths[1]}" "${paths[2]}"
tar -tzf dist/heimdall-local-linux-amd64.tar.gz
```

Use the target matching the current system for local validation. The GitHub Actions matrix performs the same packaging step on each beta target.

## Deferred limitations

- Windows binaries are out of scope for beta.
- Package-manager distribution and auto-update channels are out of scope.
- macOS code signing/notarization is deferred; release artifacts are unsigned tarballs.
- Bridge HTTPS/WSS support uses OpenSSL `s_client` for TLS validation; release packaging includes the dependency when the Nix-built `ham-bridge` output exposes `bin/openssl`, and operators may also provide OpenSSL on `PATH`.
