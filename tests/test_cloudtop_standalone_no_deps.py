#!/usr/bin/env python3
"""Comprehensive verification suite for CT-11: Zero-Dependency Standalone Packaging (Pre-Built UI, No-Nix, No-Node, MPM)."""
import os
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)

def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def main() -> None:
    print("=== CT-11 Standalone Verification Test Suite ===")

    # 1. Verify bundle archive and files
    bundle_tar = ROOT / "dist/heimdall-cloudtop-bundle.tar.gz"
    require(bundle_tar.exists(), f"Bundle archive must exist at {bundle_tar}")
    require(bundle_tar.stat().st_size > 1024 * 1024, "Bundle archive must be non-empty (>1MB)")
    print(f"[+] Bundle archive verified: {bundle_tar.name} ({bundle_tar.stat().st_size / (1024*1024):.2f} MB)")

    # 2. Extract into isolated sandbox
    temp_dir = tempfile.mkdtemp(prefix="heimdall_standalone_test_")
    try:
        sandbox_path = Path(temp_dir)
        with tarfile.open(bundle_tar, "r:gz") as tar:
            tar.extractall(sandbox_path)

        bundle_dir = sandbox_path / "heimdall-cloudtop"
        require(bundle_dir.exists(), f"Extracted bundle must contain heimdall-cloudtop directory")

        # Verify binaries
        expected_bins = ["ham-hub", "ham-bridge", "ham-dev-proxy", "ham-ctl", "ham-pty-host"]
        for bin_name in expected_bins:
            bpath = bundle_dir / "bin" / bin_name
            require(bpath.exists(), f"Binary {bin_name} must exist in bundle bin/")
            require(os.access(bpath, os.X_OK), f"Binary {bin_name} must be executable")

            # Check ldd for zero /nix/store references
            res = subprocess.run(["ldd", str(bpath)], capture_output=True, text=True)
            require(res.returncode == 0, f"ldd {bin_name} must succeed: {res.stderr}")
            nix_refs = [line for line in res.stdout.splitlines() if "/nix/store" in line]
            require(len(nix_refs) == 0, f"Binary {bin_name} must have zero /nix/store dependencies, found: {nix_refs}")

            # Check ELF interpreter via readelf / patchelf
            readelf = subprocess.run(["readelf", "-l", str(bpath)], capture_output=True, text=True)
            require("/lib64/ld-linux-x86-64.so.2" in readelf.stdout, f"Binary {bin_name} interpreter must be /lib64/ld-linux-x86-64.so.2")

        print("[+] All 5 ELF binaries verified de-Nixified with zero /nix/store references!")

        # 3. Verify static UI in bundle
        ui_dir = bundle_dir / "ui"
        require(ui_dir.exists() and ui_dir.is_dir(), "Bundle must contain ui/ directory")
        index_html = ui_dir / "index.html"
        require(index_html.exists() and index_html.stat().st_size > 200, "ui/index.html must exist and contain HTML")
        assets_dir = ui_dir / "assets"
        require(assets_dir.exists() and assets_dir.is_dir(), "ui/assets directory must exist")
        asset_files = list(assets_dir.glob("*"))
        require(len(asset_files) > 5, "ui/assets must contain pre-compiled chunks and CSS files")
        css_files = list(assets_dir.glob("*.css"))
        js_files = list(assets_dir.glob("*.js"))
        require(len(css_files) >= 1, "ui/assets must contain at least one CSS bundle")
        require(len(js_files) >= 1, "ui/assets must contain at least one JS bundle")
        print(f"[+] Pre-built static UI verified ({len(asset_files)} asset files in ui/assets)!")

        # 4. Verify MPM packaging files and dry-run
        pkgdef = ROOT / "packaging/mpm/heimdall.pkgdef"
        require(pkgdef.exists(), f"MPM pkgdef must exist at {pkgdef}")
        pkgdef_text = pkgdef.read_text(encoding="utf-8")
        require("package_name = 'heimdall/cloudtop'" in pkgdef_text, "pkgdef must declare package_name = 'heimdall/cloudtop'")
        require("package_path = '.'" in pkgdef_text, "pkgdef must declare package_path = '.'")
        require("source_dir = 'dist/heimdall-cloudtop'" in pkgdef_text, "pkgdef must declare source_dir = 'dist/heimdall-cloudtop'")

        publish_script = ROOT / "scripts/publish-mpm.sh"
        require(publish_script.exists(), "scripts/publish-mpm.sh must exist")
        require(os.access(publish_script, os.X_OK), "scripts/publish-mpm.sh must be executable")

        if shutil.which("mpm"):
            mpm_res = subprocess.run(["mpm", "build", "-n", "-f", str(pkgdef)], cwd=ROOT, capture_output=True, text=True)
            require(mpm_res.returncode == 0, f"mpm build -n must succeed:\nstdout: {mpm_res.stdout}\nstderr: {mpm_res.stderr}")
            require("Would have built version" in mpm_res.stdout, "mpm output must confirm 'Would have built version'")
            print("[+] MPM package definition validated successfully via 'mpm build -n'!")

        # 5. Verify documentation
        readme_standalone = ROOT / "README-STANDALONE.md"
        require(readme_standalone.exists(), "README-STANDALONE.md must exist in repo root")
        readme_text = readme_standalone.read_text(encoding="utf-8")
        require("mpm install heimdall/cloudtop" in readme_text, "README-STANDALONE.md must document MPM installation")
        require("tar -xzf heimdall-cloudtop-bundle.tar.gz" in readme_text, "README-STANDALONE.md must document tarball installation")
        require("Zero-Dependency" in readme_text, "README-STANDALONE.md must document zero-dependency architecture")
        print("[+] Documentation verified in README-STANDALONE.md!")

        # 6. Dynamic execution of ham-dev-proxy serving static UI
        test_port = find_free_port()
        proxy_bin = bundle_dir / "bin/ham-dev-proxy"
        # Run proxy with minimal PATH environment to prove zero Nix/Node dependency
        clean_env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(sandbox_path),
            "USER": os.environ.get("USER", "testuser"),
        }
        cmd = [
            str(proxy_bin),
            "--listen", f"127.0.0.1:{test_port}",
            "--hub-url", "http://127.0.0.1:49322",
            "--static-dir", str(ui_dir),
        ]
        proc = subprocess.Popen(cmd, env=clean_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.8)
            base_url = f"http://127.0.0.1:{test_port}"

            # Test A: GET / -> serves index.html
            req = urllib.request.Request(f"{base_url}/")
            with urllib.request.urlopen(req, timeout=5) as resp:
                require(resp.status == 200, f"GET / must return 200, got {resp.status}")
                ct = resp.headers.get("Content-Type", "")
                require("text/html" in ct, f"GET / Content-Type must be text/html, got {ct}")
                body = resp.read().decode("utf-8")
                require("<!doctype html>" in body.lower() or "<html" in body.lower(), "GET / must return HTML body")
            print("[+] Dynamic test: GET / returned index.html (200 OK)")

            # Test B: GET /assets/xxx.css -> serves static asset with Cache-Control
            css_name = css_files[0].name
            req = urllib.request.Request(f"{base_url}/assets/{css_name}")
            with urllib.request.urlopen(req, timeout=5) as resp:
                require(resp.status == 200, f"GET asset {css_name} must return 200, got {resp.status}")
                ct = resp.headers.get("Content-Type", "")
                require("text/css" in ct, f"CSS Content-Type must be text/css, got {ct}")
                cc = resp.headers.get("Cache-Control", "")
                require("public" in cc and "immutable" in cc, f"CSS Cache-Control must be immutable, got {cc}")
            print(f"[+] Dynamic test: GET /assets/{css_name} returned static CSS with Cache-Control (200 OK)")

            # Test C: GET /assets/xxx.js -> serves javascript
            js_name = js_files[0].name
            req = urllib.request.Request(f"{base_url}/assets/{js_name}")
            with urllib.request.urlopen(req, timeout=5) as resp:
                require(resp.status == 200, f"GET asset {js_name} must return 200, got {resp.status}")
                ct = resp.headers.get("Content-Type", "")
                require("javascript" in ct, f"JS Content-Type must be javascript, got {ct}")
            print(f"[+] Dynamic test: GET /assets/{js_name} returned static JS (200 OK)")

            # Test D: SPA Client Route Fallback -> GET /agents or GET /dashboard returns index.html
            for route in ["/agents", "/dashboard", "/chains/chain_123"]:
                req = urllib.request.Request(f"{base_url}{route}")
                with urllib.request.urlopen(req, timeout=5) as resp:
                    require(resp.status == 200, f"SPA route {route} must return 200, got {resp.status}")
                    ct = resp.headers.get("Content-Type", "")
                    require("text/html" in ct, f"SPA route {route} Content-Type must be text/html, got {ct}")
                    body = resp.read().decode("utf-8")
                    require("<!doctype html>" in body.lower(), f"SPA route {route} must return index.html")
            print("[+] Dynamic test: Client SPA routes fallback to index.html (200 OK)")

            # Test E: Missing asset under /assets/ returns 404
            try:
                urllib.request.urlopen(f"{base_url}/assets/nonexistent_file_xyz.js", timeout=5)
                require(False, "Missing asset should have raised HTTP 404")
            except urllib.error.HTTPError as e:
                require(e.code == 404, f"Missing asset must return 404, got {e.code}")
            print("[+] Dynamic test: Missing asset returns 404 Not Found")

            # Test F: Directory traversal rejection (403)
            # Send raw HTTP request with /../ and %2e%2e via socket
            for bad_path in [b"/../etc/passwd", b"/%2e%2e/etc/passwd", b"/assets/../../etc/shadow"]:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                    s.connect(('127.0.0.1', test_port))
                    s.sendall(b"GET " + bad_path + b" HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    raw_resp = s.recv(1024).decode("utf-8", errors="ignore")
                    require("403 Forbidden" in raw_resp, f"Directory traversal ({bad_path.decode()}) must be rejected with 403, got {raw_resp[:40]}")
            print("[+] Dynamic test: Directory traversal requests (raw, %2e%2e, and relative) returned 403 Forbidden")

        finally:
            proc.terminate()
            proc.wait(timeout=3)

        # 7. Verify start.sh / stop.sh scripts in bundle
        start_sh = bundle_dir / "start.sh"
        require(start_sh.exists(), "start.sh must exist in bundle")
        start_sh_text = start_sh.read_text(encoding="utf-8")
        require("--static-dir" in start_sh_text, "start.sh must reference --static-dir")
        require("skipping Vite dev server" in start_sh_text, "start.sh must handle skipping Vite dev server")

        install_sh = bundle_dir / "install.sh"
        require(install_sh.exists(), "install.sh must exist in bundle")
        install_sh_text = install_sh.read_text(encoding="utf-8")
        require("Copying pre-built static UI" in install_sh_text, "install.sh must copy pre-built static UI")

        print("\n=== ALL CT-11 STANDALONE VERIFICATION TESTS PASSED SUCCESSFULLY! ===")

    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)

if __name__ == "__main__":
    main()
