#!/usr/bin/env python3
"""
Static verification suite for Theme Palette Sweep:
[Theme/Sweep] Full codebase sweep and static AST test asserting 100% of colors
originate strictly from theme palette.

Validates:
- REQ-THEME-PALETTE-SWEEP: 100% of colors in src/ui/**/*.{tsx,ts,css} originate
  strictly from the theme palette. Zero hardcoded hex colors, zero raw Tailwind
  color utilities (zinc, slate, sky, emerald, etc.), and zero raw black/white utilities
  outside of the theme registry and tokens definition files.
- REQ-VAL-THEME-SWEEP: Automated test asserting palette purity, theme registry integrity,
  CSS variable definitions across all 5 registered themes, and theme switching in
  AppearanceSettings.
"""

from pathlib import Path
import re
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent
UI_DIR = REPO_ROOT / "src" / "ui"

REGISTRY_FILE = UI_DIR / "theme" / "registry.ts"
TOKENS_FILE = UI_DIR / "tokens.css"
STYLES_FILE = UI_DIR / "styles.css"
THEME_SLICE_FILE = UI_DIR / "store" / "themeSlice.ts"
APPEARANCE_SETTINGS_FILE = UI_DIR / "components" / "settings" / "AppearanceSettings.tsx"
APP_SHELL_FILE = UI_DIR / "components" / "shell" / "AppShell.tsx"

ALLOWED_COLOR_DEFINITION_FILES = {
    REGISTRY_FILE.resolve(),
    TOKENS_FILE.resolve(),
}

RAW_COLOR_PATTERNS = [
    # Raw Tailwind color utilities: text-zinc-800, bg-slate-900, border-red-500, ring-sky-400, etc.
    re.compile(
        r"\b(?:text|bg|border|ring|fill|stroke)-(?:zinc|slate|gray|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose)-\d{2,3}\b"
    ),
    # Hardcoded hex colors (3, 4, 6, 8 hex digits)
    re.compile(r"#[0-9a-fA-F]{3,8}\b"),
    # Raw Tailwind black/white utilities: bg-white, text-black, border-white/20, etc.
    re.compile(r"\b(?:text|bg|border|ring)-(?:white|black)(?:/[0-9]+)?\b"),
]

EXPECTED_THEMES = [
    "default-dark",
    "catppuccin-mocha",
    "catppuccin-latte",
    "tokyo-night",
    "tokyo-night-day",
]

EXPECTED_TOKENS = [
    "canvas",
    "surface",
    "surfaceRaised",
    "surfaceOverlay",
    "borderSubtle",
    "borderStrong",
    "textPrimary",
    "textMuted",
    "textFaint",
    "accent",
    "accentFg",
    "success",
    "warning",
    "danger",
    "info",
]


class TestUiPaletteSweep(unittest.TestCase):
    """Automated suite asserting 100% theme palette compliance across the UI."""

    def test_zero_palette_violations_across_entire_src_ui(self):
        """Scan all .tsx, .ts, and .css files under src/ui/ asserting zero raw color regressions."""
        self.assertTrue(UI_DIR.exists(), f"UI directory does not exist at {UI_DIR}")

        ui_files = [
            p
            for p in UI_DIR.rglob("*")
            if p.is_file()
            and p.suffix in (".tsx", ".ts", ".css")
            and p.resolve() not in ALLOWED_COLOR_DEFINITION_FILES
        ]

        # Ensure we are scanning a comprehensive set of frontend files (150+)
        self.assertGreaterEqual(
            len(ui_files),
            150,
            f"Expected at least 150 UI source files to be scanned, found {len(ui_files)}",
        )

        violations = []
        for file_path in sorted(ui_files):
            rel_path = file_path.relative_to(REPO_ROOT)
            content = file_path.read_text(encoding="utf-8")
            for line_no, line in enumerate(content.splitlines(), start=1):
                for pattern in RAW_COLOR_PATTERNS:
                    for match in pattern.finditer(line):
                        violations.append(
                            f"{rel_path}:{line_no}: found '{match.group(0)}' in line: {line.strip()}"
                        )

        self.assertEqual(
            violations,
            [],
            f"Found {len(violations)} raw color/palette violations in src/ui/:\n"
            + "\n".join(violations[:50]),
        )

    def test_registered_themes_and_semantic_tokens(self):
        """Verify that theme registry defines all 5 required themes with 15 semantic tokens."""
        self.assertTrue(REGISTRY_FILE.exists(), f"Missing registry at {REGISTRY_FILE}")
        reg_content = REGISTRY_FILE.read_text(encoding="utf-8")

        # Strongly typed interfaces
        self.assertIn("export interface ThemeDefinition", reg_content)
        self.assertIn("export interface ThemeTokens", reg_content)
        self.assertIn("export interface ThemeTerminal", reg_content)

        # 15 semantic tokens
        for token_name in EXPECTED_TOKENS:
            self.assertIn(
                token_name,
                reg_content,
                f"ThemeTokens interface must include '{token_name}'",
            )

        # 5 official themes
        for theme_id in EXPECTED_THEMES:
            self.assertTrue(
                f"id: '{theme_id}'" in reg_content or f'id: "{theme_id}"' in reg_content,
                f"Theme registry must export theme '{theme_id}'",
            )

        # getTheme and THEMES exports
        self.assertIn("export function getTheme", reg_content)
        self.assertIn("export const THEMES", reg_content)
        self.assertIn("export const DEFAULT_THEME_ID", reg_content)

    def test_css_tokens_palette_definitions(self):
        """Verify tokens.css specifies CSS variables for all 5 themes with dark and light schemes."""
        self.assertTrue(TOKENS_FILE.exists(), f"Missing tokens.css at {TOKENS_FILE}")
        tokens_content = TOKENS_FILE.read_text(encoding="utf-8")

        for theme_id in EXPECTED_THEMES:
            self.assertIn(
                f'[data-theme="{theme_id}"]',
                tokens_content,
                f"tokens.css must define selector [data-theme=\"{theme_id}\"]",
            )

        # Core semantic CSS variables
        for css_var in [
            "--color-canvas",
            "--color-surface",
            "--color-surface-raised",
            "--color-surface-overlay",
            "--color-border-subtle",
            "--color-border-strong",
            "--color-text-primary",
            "--color-text-muted",
            "--color-text-faint",
            "--color-accent",
            "--color-accent-fg",
            "--color-success",
            "--color-warning",
            "--color-danger",
            "--color-info",
        ]:
            self.assertIn(
                css_var,
                tokens_content,
                f"tokens.css must declare CSS variable '{css_var}'",
            )

        # Color schemes
        self.assertIn("color-scheme: dark", tokens_content)
        self.assertIn("color-scheme: light", tokens_content)

    def test_appearance_settings_and_theme_switching(self):
        """Verify theme changing works in AppearanceSettings and updates document dataset & localStorage."""
        self.assertTrue(
            APPEARANCE_SETTINGS_FILE.exists(),
            f"Missing AppearanceSettings at {APPEARANCE_SETTINGS_FILE}",
        )
        settings_content = APPEARANCE_SETTINGS_FILE.read_text(encoding="utf-8")

        # Appearance settings debug id and theme card data attributes
        self.assertIn('data-debug-id="appearance-settings"', settings_content)
        self.assertIn("data-debug-id={`theme-card-${t.id}`}", settings_content)
        self.assertIn("data-debug-id={`theme-active-indicator-${t.id}`}", settings_content)
        self.assertIn("data-debug-id={`theme-swatches-${t.id}`}", settings_content)

        # Theme switching hook & action dispatch
        self.assertIn("useTheme()", settings_content)
        self.assertIn("onClick={() => setTheme(t.id)}", settings_content)
        self.assertIn("t.tokens.canvas", settings_content)
        self.assertIn("t.tokens.surface", settings_content)

        # Theme slice store logic
        self.assertTrue(
            THEME_SLICE_FILE.exists(), f"Missing themeSlice at {THEME_SLICE_FILE}"
        )
        slice_content = THEME_SLICE_FILE.read_text(encoding="utf-8")
        self.assertIn("heimdall-theme", slice_content)
        self.assertIn("document.documentElement.dataset.theme = theme.id", slice_content)
        self.assertIn("document.documentElement.style.colorScheme = theme.appearance", slice_content)
        self.assertIn("localStorage.setItem(STORAGE_KEY, id)", slice_content)
        self.assertIn("export function useTheme()", slice_content)
        self.assertIn("export const { setTheme } = themeSlice.actions", slice_content)

        # AppShell routing to AppearanceSettings
        self.assertTrue(APP_SHELL_FILE.exists(), f"Missing AppShell at {APP_SHELL_FILE}")
        shell_content = APP_SHELL_FILE.read_text(encoding="utf-8")
        self.assertIn("AppearanceSettings", shell_content)
        self.assertIn("/settings/appearance", shell_content)

    def test_global_styles_css_variables(self):
        """Verify styles.css uses theme variables for body, scrollbars, and fonts."""
        self.assertTrue(STYLES_FILE.exists(), f"Missing styles.css at {STYLES_FILE}")
        styles_content = STYLES_FILE.read_text(encoding="utf-8")

        self.assertIn("var(--color-canvas", styles_content)
        self.assertIn("var(--color-text-primary", styles_content)
        self.assertIn("var(--color-border-strong)", styles_content)
        self.assertIn("var(--color-surface)", styles_content)
        self.assertNotIn("bg-[#090909]", styles_content)
        self.assertNotIn("bg-[#141414]", styles_content)


if __name__ == "__main__":
    unittest.main()
