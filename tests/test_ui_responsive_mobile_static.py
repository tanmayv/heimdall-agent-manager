#!/usr/bin/env python3
"""Static guard for UI-13: responsive/mobile behavior (breakpoints, collapse
strategy, bottom tab bar, safe-area/keyboard-aware composer, touch targets,
layout-independent data-debug-id)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESPONSIVE = ROOT / "src" / "ui" / "components" / "shell" / "responsive.tsx"
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
COMPOSER = ROOT / "src" / "ui" / "components" / "chat" / "ChatComposer.tsx"
COMPOSER_TYPES = ROOT / "src" / "ui" / "components" / "chat" / "types.ts"
INSPECTOR = ROOT / "src" / "ui" / "components" / "workspace" / "ContextInspector.tsx"
STYLES = ROOT / "src" / "ui" / "styles.css"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    responsive = RESPONSIVE.read_text(encoding="utf-8")
    shell = SHELL.read_text(encoding="utf-8")
    composer = COMPOSER.read_text(encoding="utf-8")
    composer_types = COMPOSER_TYPES.read_text(encoding="utf-8")
    inspector = INSPECTOR.read_text(encoding="utf-8")
    styles = STYLES.read_text(encoding="utf-8")

    # --- Breakpoints + viewport primitives ---
    for marker in ["MOBILE_MAX", "TABLET_MAX", "type Viewport", "'mobile' | 'tablet' | 'desktop'", "useViewport", "useIsMobile"]:
        require(marker in responsive, f"responsive primitives missing: {marker}")
    # Breakpoint floors match the arch doc: <768 mobile, 768–1024 tablet, >1024 desktop.
    require("MOBILE_MAX = 767" in responsive, "mobile breakpoint must be 767 (<=767px mobile)")
    require("TABLET_MAX = 1023" in responsive, "tablet breakpoint must be 1023 (<=1023px tablet)")

    # --- Touch-target floor (>=44px) ---
    require("TOUCH_TARGET_CLASS" in responsive and "min-h-11" in responsive and "min-w-11" in responsive,
            "TOUCH_TARGET_CLASS must enforce a >=44px (min-h/w-11) hit area")

    # --- Bottom tab bar: Chat / Chains / (palette center) / Library / More ---
    for marker in [
        "shell-mobile-tab-bar",
        "MobileTabBar",
        "'chat'",
        "'chains'",
        "'library'",
        "'more'",
        "onOpenPalette",
        "md:hidden",
    ]:
        require(marker in responsive, f"MobileTabBar missing: {marker}")
    # Center button = command palette (dedicated center button per arch doc §6D).
    require("grid grid-cols-5" in responsive, "bottom tab bar must lay out 5 columns with a centered palette button")
    # Outer tabs navigate; center opens palette (not a nav item).
    require("onNavigate" in responsive and "TABS" in responsive, "bottom tab bar tabs must navigate")
    # Badges wired (Chat = total unread, Chains = unread task/review activity).
    require("chatBadge" in responsive and "chainsBadge" in responsive, "bottom tab bar must support per-tab unread badges")

    # --- Off-canvas drawer (sidebar) + mobile top bar ---
    for marker in ["MobileTopBar", "shell-mobile-top-bar", "shell-mobile-drawer-open", "shell-mobile-title", "onOpenDrawer"]:
        require(marker in responsive, f"MobileTopBar missing: {marker}")
    # Mobile back header for chain drill-down (list -> tap task -> detail).
    for marker in ["MobileBackHeader", "shell-mobile-back-header", "shell-mobile-back-btn", "onBack"]:
        require(marker in responsive, f"MobileBackHeader (chain drill-down) missing: {marker}")

    # --- Mobile inspector = bottom sheet; same workspace-inspector debug-id ---
    for marker in ["MobileInspectorSheet", "shell-mobile-inspector-sheet-root", "shell-mobile-inspector-sheet-scrim", "data-mobile-sheet"]:
        require(marker in responsive, f"MobileInspectorSheet missing: {marker}")
    # The mobile sheet reuses the canonical inspector id (layout-independent).
    require('data-debug-id="workspace-inspector"' in responsive,
            "mobile inspector sheet must reuse the canonical workspace-inspector debug-id")
    # Keyboard-aware: lifts above the soft keyboard via an inset prop.
    require("keyboardInset" in responsive and "useKeyboardInset" in responsive,
            "mobile inspector sheet must be keyboard-aware")

    # --- AppShell wires the mobile chrome ---
    for marker in [
        "MobileTabBar",
        "MobileTopBar",
        "useViewport",
        "shell-mobile-drawer-scrim",
        "shell-mobile-palette-button",  # canonical palette entry id (now in the tab bar center)
        "drawerOpen",
    ]:
        require(marker in shell, f"AppShell missing mobile chrome wiring: {marker}")
    # The tab bar component (carrying shell-mobile-tab-bar) is rendered by the shell.
    require("<MobileTabBar" in shell, "AppShell must render <MobileTabBar>")
    require("<MobileTopBar" in shell, "AppShell must render <MobileTopBar>")
    # Sidebar is an off-canvas drawer on mobile (fixed + translate).
    require("fixed inset-y-0 left-0 z-50" in shell and "-translate-x-full" in shell,
            "AppShell sidebar must be an off-canvas drawer on mobile (fixed + translate when closed)")
    # The redundant floating palette button must be gone (replaced by the tab-bar center button).
    require(shell.count("shell-mobile-palette-button") == 1,
            "AppShell must have exactly one mobile palette entry id (the tab-bar center button), not a duplicate floating button")
    # Route outlet reserves bottom padding so content clears the fixed tab bar.
    require("mobileBottomPadded" in shell and "pb-20" in shell,
            "AppShell route outlet must reserve bottom padding on mobile to clear the tab bar")

    # --- Composer: keyboard/safe-area-aware, bottom-pinned, touch-target send ---
    for marker in [
        "useIsMobile",
        "useKeyboardInset",
        "TOUCH_TARGET_CLASS",
        "mobileBottomPinned",
        "ui-safe-bottom",
        "sticky bottom-0",
        "data-mobile-bottom-pinned",
    ]:
        require(marker in composer, f"ChatComposer missing mobile ergonomics: {marker}")
    # Mobile send button grows to a >=44px touch target.
    require("min-h-11" in composer and "px-4" in composer,
            "ChatComposer send button must be a >=44px touch target on mobile")
    # Keyboard inset is applied as bottom padding (lifts composer above the keyboard).
    require("paddingBottom: keyboardInset" in composer,
            "ChatComposer must lift above the soft keyboard using the keyboard inset")
    # The opt-in prop is part of the typed composer contract.
    require("mobileBottomPinned?: boolean" in composer_types,
            "ChatComposerProps must declare mobileBottomPinned?: boolean")

    # --- ContextInspector: viewport-aware (desktop right-aside vs mobile sheet) ---
    for marker in ["useViewport", "MobileInspectorSheet", "renderTabsAndPanel", "workspace-inspector-tabs"]:
        require(marker in inspector, f"ContextInspector missing responsive variant: {marker}")
    # The same tab debug-ids render on both layouts (layout-independent).
    require("tab.buttonDebugId" in inspector,
            "ContextInspector must keep tab debug-ids layout-independent across desktop/mobile")

    # --- styles.css: drop desktop min-width on mobile + safe-area utilities ---
    require("@media (max-width: 767px)" in styles and "min-width: 0" in styles,
            "styles.css must drop the desktop min-width floor below the mobile breakpoint")
    for marker in ["ui-safe-bottom", "ui-safe-top", "env(safe-area-inset-bottom)"]:
        require(marker in styles, f"styles.css missing safe-area utility: {marker}")

    print("PASS: UI-13 responsive/mobile static")


if __name__ == "__main__":
    main()
