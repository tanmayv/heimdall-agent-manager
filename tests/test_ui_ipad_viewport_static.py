#!/usr/bin/env python3
"""Static verification guard for iPad / tablet viewport-constrained layout
and dev-preview production upstream connection.

Requirements covered:
- REQ-IPAD-1: Viewport locking in styles.css for html, body, #root:
  width: 100%, height: 100%, height: 100dvh, max-width: 100vw, max-height: 100dvh,
  overflow: hidden, overscroll-behavior: none.
- REQ-IPAD-2: Removal of global desktop min-width: 920px and min-height: 620px floor
  from body so iPad portrait (768px-834px) fits without document scroll.
- REQ-IPAD-3: AppShell root container uses fixed inset-0 flex h-full w-full max-w-full
  overflow-hidden bg-canvas text-primary. Aside, header, and BottomDock remain shrink-0.
- REQ-PREVIEW-1: scripts/dev-preview.mjs supports --prod flag and HEIMDALL_PREVIEW_PROD env
  var, passing VITE_API_BASE: '' to connect to production Hub at browser origin.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
STYLES_FILE = ROOT / "src" / "ui" / "styles.css"
APPSHELL_FILE = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
BOTTOMDOCK_FILE = ROOT / "src" / "ui" / "components" / "shell" / "BottomDock.tsx"
DEV_PREVIEW_FILE = ROOT / "scripts" / "dev-preview.mjs"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_styles_css_viewport_locking():
    """Verify REQ-IPAD-1: html, body, #root viewport locking in src/ui/styles.css."""
    require(STYLES_FILE.exists(), f"styles.css must exist at {STYLES_FILE}")
    css = STYLES_FILE.read_text(encoding="utf-8")

    # Match html, body, #root rule
    match = re.search(r"html\s*,\s*body\s*,\s*#root\s*\{([^}]+)\}", css)
    require(match is not None, "styles.css must define 'html, body, #root' rule block")

    block = match.group(1)
    require("margin: 0;" in block, "html, body, #root must specify 'margin: 0;'")
    require("padding: 0;" in block, "html, body, #root must specify 'padding: 0;'")
    require("width: 100%;" in block, "html, body, #root must specify 'width: 100%;'")
    require("height: 100%;" in block, "html, body, #root must specify 'height: 100%;'")
    require("height: 100dvh;" in block, "html, body, #root must specify 'height: 100dvh;'")
    require("max-width: 100vw;" in block, "html, body, #root must specify 'max-width: 100vw;'")
    require("max-height: 100dvh;" in block, "html, body, #root must specify 'max-height: 100dvh;'")
    require("overflow: hidden;" in block, "html, body, #root must specify 'overflow: hidden;'")
    require("overscroll-behavior: none;" in block, "html, body, #root must specify 'overscroll-behavior: none;'")


def test_styles_css_no_min_dimensions_floor():
    """Verify REQ-IPAD-2: removal of min-width: 920px and min-height: 620px from body."""
    css = STYLES_FILE.read_text(encoding="utf-8")

    require("min-width: 920px" not in css, "styles.css must not have min-width: 920px floor on body")
    require("min-height: 620px" not in css, "styles.css must not have min-height: 620px floor on body")


def test_app_shell_root_container():
    """Verify REQ-IPAD-3: AppShell root container and shrink-0 navigation chrome."""
    require(APPSHELL_FILE.exists(), f"AppShell.tsx must exist at {APPSHELL_FILE}")
    src = APPSHELL_FILE.read_text(encoding="utf-8")

    # Check root container
    require(
        'data-debug-id="app-shell"' in src,
        "AppShell.tsx must render app-shell element",
    )
    require(
        'className="fixed inset-0 flex h-full w-full max-w-full overflow-hidden bg-canvas text-primary"' in src,
        "AppShell.tsx root app-shell must use 'fixed inset-0 flex h-full w-full max-w-full overflow-hidden bg-canvas text-primary'",
    )

    # Check that navigation chrome components are shrink-0
    require(
        "shrink-0" in src,
        "AppShell.tsx must have shrink-0 elements",
    )
    # aside check
    require(
        "<aside" in src and "shrink-0" in src,
        "AppShell aside navigation must include shrink-0",
    )
    # header check (REQ-TOPBAR-RM-1: top header removed)
    require(
        'data-debug-id="shell-top-header"' not in src,
        "AppShell top header must be removed",
    )

    # BottomDock check
    dock_src = BOTTOMDOCK_FILE.read_text(encoding="utf-8")
    require(
        'data-debug-id="bottom-dock-container"' in dock_src and "shrink-0" in dock_src,
        "BottomDock root container must include shrink-0",
    )


def test_dev_preview_prod_upstream():
    """Verify REQ-PREVIEW-1: scripts/dev-preview.mjs supports --prod flag."""
    require(DEV_PREVIEW_FILE.exists(), f"dev-preview.mjs must exist at {DEV_PREVIEW_FILE}")
    src = DEV_PREVIEW_FILE.read_text(encoding="utf-8")

    # Check isProd parsing
    require(
        "isProd" in src,
        "scripts/dev-preview.mjs must define isProd",
    )
    require(
        "process.argv.includes('--prod')" in src or 'process.argv.includes("--prod")' in src,
        "scripts/dev-preview.mjs must check process.argv for '--prod'",
    )
    require(
        "HEIMDALL_PREVIEW_PROD" in src,
        "scripts/dev-preview.mjs must check HEIMDALL_PREVIEW_PROD env var",
    )

    # Check startVite sets VITE_API_BASE conditionally
    require(
        "VITE_API_BASE: isProd ? '' :" in src or 'VITE_API_BASE: isProd ? "" :' in src,
        "scripts/dev-preview.mjs startVite must set VITE_API_BASE to empty string when isProd is true",
    )
    require(
        "VITE_BASE_API: isProd ? '' :" in src or 'VITE_BASE_API: isProd ? "" :' in src,
        "scripts/dev-preview.mjs startVite must set VITE_BASE_API to empty string when isProd is true",
    )


def main():
    print("Running static verification tests for iPad viewport and dev-preview prod mode...")
    test_styles_css_viewport_locking()
    print("PASS: REQ-IPAD-1 (html, body, #root viewport locking)")
    test_styles_css_no_min_dimensions_floor()
    print("PASS: REQ-IPAD-2 (no desktop min-width/min-height floor)")
    test_app_shell_root_container()
    print("PASS: REQ-IPAD-3 (AppShell root container fixed inset-0 overflow-hidden and shrink-0 chrome)")
    test_dev_preview_prod_upstream()
    print("PASS: REQ-PREVIEW-1 (dev-preview --prod flag and empty VITE_API_BASE)")
    print("All static tests passed successfully!")


if __name__ == "__main__":
    main()
