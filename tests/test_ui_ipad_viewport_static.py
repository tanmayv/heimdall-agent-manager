#!/usr/bin/env python3
"""Static verification guard for iPad / tablet viewport-constrained layout
and dev-preview production upstream connection.

Requirements covered:
- REQ-IPAD-1: Viewport locking in styles.css for html, body, #root:
  width: 100%, height: 100%, height: var(--app-viewport-height), max-width: 100vw,
  max-height: var(--app-viewport-height), overflow: hidden, overscroll-behavior: none.
  (REQ-KBD-2 replaced the literal 100dvh with the visual-viewport-driven var.)
- REQ-IPAD-2: Removal of global desktop min-width: 920px and min-height: 620px floor
  from body so iPad portrait (768px-834px) fits without document scroll.
- REQ-IPAD-3: AppShell root container uses fixed inset-x-0 top-0 app-viewport-height flex
  w-full max-w-full overflow-hidden bg-canvas text-primary (REQ-KBD-2: was inset-0/h-full). Aside, header, and BottomDock remain shrink-0.
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
    # REQ-KBD-2 changed the SOURCE of the height, not the lock. REQ-IPAD-1's requirement is
    # a single fixed-height, non-scrolling document box; `100dvh` was merely how that height
    # was obtained, and it was wrong on iOS: `dvh` does not shrink for a software keyboard,
    # so a `100dvh` box left 403px of the app permanently behind the keyboard. The height now
    # comes from `--app-viewport-height` (= `visualViewport.height`, published by
    # src/ui/utils/appViewportHeight.ts), whose `:root` fallback is `100dvh`. Do not revert
    # these two lines to a literal `100dvh`.
    require("height: var(--app-viewport-height);" in block,
            "html, body, #root must take their height from var(--app-viewport-height)")
    require("max-width: 100vw;" in block, "html, body, #root must specify 'max-width: 100vw;'")
    require("max-height: var(--app-viewport-height);" in block,
            "html, body, #root must cap max-height at var(--app-viewport-height)")
    require(re.search(r"--app-viewport-height:\s*100dvh;", css) is not None,
            "styles.css :root must define the --app-viewport-height fallback as 100dvh")
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
    # REQ-KBD-2: was 'fixed inset-0 flex h-full w-full max-w-full …'. `inset-0` pinned the
    # BOTTOM edge to the layout viewport and `h-full` on a fixed element resolves against
    # that same layout viewport (not #root), so this box stayed 812px tall while only the
    # top 409px were visible — the composer sat at 540..776, inside the invisible 403px.
    # It must now pin only the top and take its height from --app-viewport-height.
    # REQ-IPAD-3's intent (one fixed, overflow-hidden, full-width flex shell) is unchanged.
    require(
        'className="fixed inset-x-0 top-0 app-viewport-height flex w-full max-w-full overflow-hidden bg-canvas text-primary"' in src,
        "AppShell.tsx root app-shell must use 'fixed inset-x-0 top-0 app-viewport-height flex w-full max-w-full overflow-hidden bg-canvas text-primary'",
    )
    require(
        '"fixed inset-0 flex h-full' not in src,
        "AppShell.tsx app-shell must not pin its bottom edge to the layout viewport (REQ-KBD-2)",
    )
    require(
        re.search(r"\.app-viewport-height\s*\{[^}]*height:\s*var\(--app-viewport-height\)", STYLES_FILE.read_text(encoding="utf-8")) is not None,
        "styles.css must define the .app-viewport-height utility the app-shell relies on",
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
    print("PASS: REQ-IPAD-3 (AppShell root container fixed inset-x-0/top-0, visual-viewport height, overflow-hidden, shrink-0 chrome)")
    test_dev_preview_prod_upstream()
    print("PASS: REQ-PREVIEW-1 (dev-preview --prod flag and empty VITE_API_BASE)")
    print("All static tests passed successfully!")


if __name__ == "__main__":
    main()
