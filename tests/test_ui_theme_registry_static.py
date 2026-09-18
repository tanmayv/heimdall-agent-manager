#!/usr/bin/env python3
"""Static analysis and verification suite for the Declarative Theme Registry,
CSS token palettes, theme persistence, and dynamic theme switching.
Requirements: REQ-THEME-TOKENS, REQ-THEME-REGISTRY, REQ-THEME-STORE, REQ-THEME-UI, REQ-THEME-EXTERNALS.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

REGISTRY_FILE = ROOT / "src" / "ui" / "theme" / "registry.ts"
TOKENS_FILE = ROOT / "src" / "ui" / "tokens.css"
STORE_FILE = ROOT / "src" / "ui" / "store" / "themeSlice.ts"
ROOT_STORE_FILE = ROOT / "src" / "ui" / "store" / "store.ts"
SETTINGS_FILE = ROOT / "src" / "ui" / "components" / "settings" / "AppearanceSettings.tsx"
SHELL_FILE = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
COMMAND_PALETTE_FILE = ROOT / "src" / "ui" / "components" / "ui" / "patterns" / "CommandPalette.tsx"
CODE_HIGHLIGHT_FILE = ROOT / "src" / "ui" / "utils" / "codeHighlight.ts"
COMPOSER_PANEL_FILE = ROOT / "src" / "ui" / "components" / "chat" / "AgentPaneComposerPanel.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)
    print(f"[+] PASS: {message}")


def main() -> None:
    print("=== Checking REQ-THEME-REGISTRY: Declarative Theme Registry ===")
    require(REGISTRY_FILE.exists(), f"Registry file must exist at {REGISTRY_FILE}")
    reg_content = REGISTRY_FILE.read_text(encoding="utf-8")

    # Interface declarations
    require("export interface ThemeDefinition" in reg_content, "ThemeDefinition interface must be exported")
    require("export interface ThemeTokens" in reg_content, "ThemeTokens interface must be exported")
    require("export interface ThemeTerminal" in reg_content, "ThemeTerminal interface must be exported")

    # 15 semantic tokens strongly typed
    expected_tokens = [
        "canvas", "surface", "surfaceRaised", "surfaceOverlay",
        "borderSubtle", "borderStrong",
        "textPrimary", "textMuted", "textFaint",
        "accent", "accentFg",
        "success", "warning", "danger", "info"
    ]
    for tok in expected_tokens:
        require(tok in reg_content, f"ThemeTokens must include '{tok}'")

    # Terminal ANSI colors strongly typed
    expected_terminal_keys = [
        "background", "foreground", "cursor", "cursorAccent", "selectionBackground",
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue",
        "brightMagenta", "brightCyan", "brightWhite"
    ]
    for tk in expected_terminal_keys:
        require(tk in reg_content, f"ThemeTerminal must include '{tk}'")

    # 5 themes defined in THEMES array
    expected_themes = [
        "default-dark",
        "catppuccin-mocha",
        "catppuccin-latte",
        "tokyo-night",
        "tokyo-night-day"
    ]
    for th in expected_themes:
        require(f"id: '{th}'" in reg_content or f'id: "{th}"' in reg_content,
                f"THEMES array must contain theme with id '{th}'")

    # Strict palette colors check
    require("#181825" in reg_content, "Catppuccin Mocha canvas must use mantle #181825")
    require("#1e1e2e" in reg_content, "Catppuccin Mocha surface must use base #1e1e2e")
    require("#eff1f5" in reg_content, "Catppuccin Latte surface must use base #eff1f5")
    require("#16161e" in reg_content, "Tokyo Night canvas must use bg_dark #16161e")
    require("#e1e2e7" in reg_content, "Tokyo Night Day surface must use bg #e1e2e7")

    # Helper utilities
    require("export function getTheme" in reg_content, "getTheme function must be exported")
    require("export const DEFAULT_THEME_ID" in reg_content, "DEFAULT_THEME_ID must be exported")
    require("export const THEMES" in reg_content, "THEMES array must be exported")

    print("\n=== Checking REQ-THEME-TOKENS: CSS Token Palettes ===")
    require(TOKENS_FILE.exists(), f"tokens.css must exist at {TOKENS_FILE}")
    tokens_content = TOKENS_FILE.read_text(encoding="utf-8")

    for th in expected_themes:
        require(f'[data-theme="{th}"]' in tokens_content,
                f"tokens.css must define selector [data-theme=\"{th}\"]")

    require("color-scheme: dark" in tokens_content, "tokens.css must define dark color-scheme")
    require("color-scheme: light" in tokens_content, "tokens.css must define light color-scheme")
    require("color-mix" in tokens_content, "tokens.css must compute soft tints via color-mix")

    print("\n=== Checking REQ-THEME-STORE: Theme Store & Persistence ===")
    require(STORE_FILE.exists(), f"themeSlice.ts must exist at {STORE_FILE}")
    store_content = STORE_FILE.read_text(encoding="utf-8")

    require("themeSlice" in store_content, "themeSlice must be defined")
    require("setTheme" in store_content, "setTheme action must be exported")
    require("useTheme" in store_content, "useTheme hook must be exported")
    require("heimdall-theme" in store_content, "Theme must persist to localStorage with 'heimdall-theme' key")
    require("document.documentElement.dataset.theme" in store_content,
            "themeSlice must bind to document.documentElement.dataset.theme")
    require("document.documentElement.style.colorScheme" in store_content,
            "themeSlice must bind to document.documentElement.style.colorScheme")

    require(ROOT_STORE_FILE.exists(), "Root store.ts must exist")
    root_store_content = ROOT_STORE_FILE.read_text(encoding="utf-8")
    require("themeReducer" in root_store_content or "theme:" in root_store_content,
            "Root store must include themeReducer in appReducer")

    print("\n=== Checking REQ-THEME-UI: Theme Selector & Appearance Settings ===")
    require(SETTINGS_FILE.exists(), f"AppearanceSettings.tsx must exist at {SETTINGS_FILE}")
    settings_content = SETTINGS_FILE.read_text(encoding="utf-8")

    require("export function AppearanceSettings" in settings_content or "export default function AppearanceSettings" in settings_content,
            "AppearanceSettings component must be exported")
    require("useTheme" in settings_content, "AppearanceSettings must consume useTheme hook")
    require("data-debug-id=\"appearance-settings\"" in settings_content,
            "AppearanceSettings must have data-debug-id='appearance-settings'")
    require("Badge" in settings_content, "AppearanceSettings must render Dark/Light badges")

    require(SHELL_FILE.exists(), "AppShell.tsx must exist")
    shell_content = SHELL_FILE.read_text(encoding="utf-8")
    require("AppearanceSettings" in shell_content, "AppShell must import AppearanceSettings")
    require("/settings/appearance" in shell_content, "AppShell must route /settings/appearance")

    require(COMMAND_PALETTE_FILE.exists(), "CommandPalette.tsx must exist")
    cp_content = COMMAND_PALETTE_FILE.read_text(encoding="utf-8")
    require("THEMES" in cp_content or "settings-appearance" in cp_content,
            "CommandPalette must include theme actions or navigation")

    print("\n=== Checking REQ-THEME-EXTERNALS: Dynamic Shiki & xterm Integration ===")
    require(CODE_HIGHLIGHT_FILE.exists(), "codeHighlight.ts must exist")
    ch_content = CODE_HIGHLIGHT_FILE.read_text(encoding="utf-8")
    require("catppuccin-mocha" in ch_content, "codeHighlight.ts must support catppuccin-mocha")
    require("catppuccin-latte" in ch_content, "codeHighlight.ts must support catppuccin-latte")
    require("tokyo-night" in ch_content, "codeHighlight.ts must support tokyo-night")
    require("github-dark" in ch_content, "codeHighlight.ts must support github-dark")
    require("getActiveShikiTheme" in ch_content or "ensureTheme" in ch_content,
            "codeHighlight.ts must dynamically resolve active theme")

    require(COMPOSER_PANEL_FILE.exists(), "AgentPaneComposerPanel.tsx must exist")
    panel_content = COMPOSER_PANEL_FILE.read_text(encoding="utf-8")
    require("useTheme" in panel_content, "AgentPaneComposerPanel must consume useTheme")
    require("options.theme" in panel_content or "theme.terminal" in panel_content,
            "AgentPaneComposerPanel must bind terminal palette to active theme")

    print("\n[+] ALL STATIC THEME REGISTRY CHECKS PASSED (REQ-THEME-TOKENS, REQ-THEME-REGISTRY, REQ-THEME-STORE, REQ-THEME-UI, REQ-THEME-EXTERNALS)")


if __name__ == "__main__":
    main()
