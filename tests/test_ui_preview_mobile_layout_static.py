#!/usr/bin/env python3
"""Static verification guard for mobile preview floating icon repositioning
and mobile Drawer 100% full-height without redundant header.

Requirements covered:
- REQ-UI-PREVIEW-FLOATING-ICON-POSITION:
  PreviewSidebar.tsx floating button is positioned at 'fixed top-16 right-3 z-40',
  below the mobile sidebar toggle icon instead of hovering over bottom composer controls.
- REQ-UI-PREVIEW-MOBILE-FULLHEIGHT:
  - DrawerProps in Drawer.tsx supports hideHeader?: boolean and fullHeight?: boolean.
  - Drawer.tsx suppresses the header bar when hideHeader is true while keeping aria accessible (aria-label).
  - Drawer.tsx expands to full viewport height (h-full max-h-full w-full rounded-none border-t-0)
    when side='bottom' and fullHeight is true.
  - PreviewSidebar.tsx mobile Drawer invocation specifies hideHeader, fullHeight,
    and className containing ui-safe-top, ui-safe-bottom, h-full, max-h-full.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRAWER_FILE = ROOT / "src" / "ui" / "components" / "ui" / "composites" / "Drawer.tsx"
PREVIEW_SIDEBAR_FILE = ROOT / "src" / "ui" / "components" / "shells" / "PreviewSidebar.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_drawer_props_and_implementation():
    require(DRAWER_FILE.is_file(), f"Drawer.tsx must exist at {DRAWER_FILE}")
    src = DRAWER_FILE.read_text(encoding="utf-8")

    # 1. DrawerProps has hideHeader and fullHeight
    require("hideHeader?: boolean;" in src,
            "DrawerProps must include 'hideHeader?: boolean;'")
    require("fullHeight?: boolean;" in src,
            "DrawerProps must include 'fullHeight?: boolean;'")

    # 2. DrawerBase destructures hideHeader and fullHeight with defaults
    require("hideHeader = false" in src,
            "DrawerBase must default hideHeader = false")
    require("fullHeight = false" in src,
            "DrawerBase must default fullHeight = false")

    # 3. fullHeight on side='bottom' uses full viewport height
    require("fullHeight ? 'h-full max-h-full w-full rounded-none border-t-0' : SIDE_CLASS.bottom" in src,
            "DrawerBase must use 'h-full max-h-full w-full rounded-none border-t-0' when fullHeight and side='bottom'")

    # 4. hideHeader suppresses header div and manages a11y attributes
    require("!hideHeader &&" in src or "{!hideHeader && (" in src,
            "DrawerBase must conditionally render header div only when !hideHeader")
    require("aria-labelledby={hideHeader ? undefined : titleId}" in src,
            "DrawerBase must omit aria-labelledby when hideHeader is true")
    require("aria-label={hideHeader ?" in src,
            "DrawerBase must set aria-label on dialog when hideHeader is true")


def test_preview_sidebar_mobile_floating_button_and_drawer():
    require(PREVIEW_SIDEBAR_FILE.is_file(), f"PreviewSidebar.tsx must exist at {PREVIEW_SIDEBAR_FILE}")
    src = PREVIEW_SIDEBAR_FILE.read_text(encoding="utf-8")

    # 1. Floating button repositioned to fixed top-16 right-3 z-40
    require("fixed top-16 right-3 z-40" in src,
            "PreviewSidebar mobile expand button must be positioned at 'fixed top-16 right-3 z-40'")
    require("bottom-24" not in src,
            "PreviewSidebar mobile expand button must no longer use bottom-24")

    # 2. Mobile Drawer invocation uses hideHeader and fullHeight
    require("<Drawer" in src, "PreviewSidebar must invoke Drawer")
    require("hideHeader" in src,
            "PreviewSidebar mobile Drawer must include hideHeader prop")
    require("fullHeight" in src,
            "PreviewSidebar mobile Drawer must include fullHeight prop")
    require("ui-safe-top" in src and "ui-safe-bottom" in src and "h-full" in src and "max-h-full" in src and "md:hidden" in src,
            "PreviewSidebar mobile Drawer must have className with ui-safe-top ui-safe-bottom h-full max-h-full md:hidden")


def main():
    test_drawer_props_and_implementation()
    test_preview_sidebar_mobile_floating_button_and_drawer()
    print("PASS: test_ui_preview_mobile_layout_static")


if __name__ == "__main__":
    main()
