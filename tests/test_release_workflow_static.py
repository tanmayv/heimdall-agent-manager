#!/usr/bin/env python3
"""Static checks for HBR-26 release binary workflow and packaging."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release-local-binaries.yml"
SCRIPT = ROOT / "scripts/release/package-local-binary-tarball.sh"
DOCS = ROOT / "docs/release-local-binaries.md"


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def main() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    script = SCRIPT.read_text(encoding="utf-8")
    docs = DOCS.read_text(encoding="utf-8")

    for target in ["darwin-arm64", "darwin-amd64", "linux-amd64", "linux-arm64"]:
        tarball = f"heimdall-local-{target}.tar.gz"
        require(target in workflow, f"workflow missing matrix target {target}")
        require(tarball in workflow, f"workflow missing tarball {tarball}")
        require(tarball in docs, f"docs missing tarball {tarball}")

    for runner in ["macos-14", "macos-15-intel", "ubuntu-24.04", "ubuntu-24.04-arm"]:
        require(runner in workflow, f"workflow missing runner {runner}")
    for system in ["aarch64-darwin", "x86_64-darwin", "x86_64-linux", "aarch64-linux"]:
        require(system in workflow, f"workflow missing Nix system guard {system}")
    require("builtins.currentSystem" in workflow and "runner Nix system mismatch" in workflow, "workflow must guard native runner system")

    for package in [".#ham-bridge", ".#ham-wrapper", ".#ham-ctl"]:
        require(package in workflow, f"workflow missing Nix package build {package}")

    require("pkgs.openssl" in (ROOT / "flake.nix").read_text(encoding="utf-8"), "ham-bridge release build must account for OpenSSL TLS dependency")
    require("bin/openssl" in script and "tls_dependency" in script, "package script must carry TLS dependency metadata and bundled openssl when available")

    for entry in ["bin/ham-bridge", "bin/ham-wrapper", "bin/ham-ctl", "README.md", "LICENSE"]:
        require(entry in workflow, f"workflow missing tar verification for {entry}")
        require(entry in script, f"package script missing tar entry {entry}")
        require(entry in docs, f"docs missing tar entry {entry}")

    require("SHA256SUMS" in workflow and "sha256sum" in workflow, "workflow must produce SHA256SUMS manifest")
    require("heimdall-local-${{ matrix.target }}-${{ steps.version.outputs.version }}" in workflow, "workflow artifact names must include target and version")
    require('asset="heimdall-local-${target}-${version}.tar.gz"' in workflow and 'dist/heimdall-local-*-"$VERSION".tar.gz' in workflow, "release assets must be versioned by target and tag")
    require("heimdall-local-linux-amd64-v0.1.0-beta.1.tar.gz" in docs, "docs must show versioned release asset names")
    require("permissions:" in workflow and "contents: read" in workflow and "contents: write" in workflow, "workflow must declare least-privilege permissions")
    require("push:" in workflow and "tags:" in workflow and "workflow_dispatch:" in workflow, "workflow must support tag and dispatch triggers")
    require("persist-credentials: false" in workflow, "checkout should not persist credentials")
    require("GITHUB_TOKEN" in docs or "GITHUB_TOKEN" in workflow, "release path must document/use built-in token only")
    require("set -euo pipefail" in workflow and "set -euo pipefail" in script, "workflow/script must fail clearly")
    require("code signing/notarization is deferred" in docs, "docs must state signing limitation")

    print("PASS: release workflow static")


if __name__ == "__main__":
    main()
