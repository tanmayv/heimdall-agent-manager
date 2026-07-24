#!/usr/bin/env python3
"""Static guard for UI-12: unified command palette (navigation + entities + actions)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PALETTE = ROOT / "src" / "ui" / "components" / "command-palette" / "CommandPalette.tsx"
SEARCH = ROOT / "src" / "ui" / "api" / "endpoints" / "search.ts"
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    palette = PALETTE.read_text(encoding="utf-8")
    search = SEARCH.read_text(encoding="utf-8")
    shell = SHELL.read_text(encoding="utf-8")

    # --- Palette is one unified overlay handling nav + entities + actions ---
    for marker in [
        "command-palette",
        "command-palette-panel",
        "command-palette-input",
        "Type a command or search",
        "command-palette-empty",
        "useGlobalSearchQuery",
        "DEFAULT_NAV",
        "DEFAULT_ACTIONS",
    ]:
        require(marker in palette, f"CommandPalette missing: {marker}")
    # Grouped results: Navigate, Actions, and entity groups.
    require("group: 'Navigate'" in palette, "Palette must group navigation results")
    require("group: 'Actions'" in palette, "Palette must group action results")
    require("kind: 'entity'" in palette and "kind: 'navigate'" in palette and "kind: 'action'" in palette,
            "Palette must classify navigate/entity/action results")
    # Keyboard-first: up/down/enter/esc.
    for key in ["ArrowDown", "ArrowUp", "Enter", "Escape"]:
        require(f"event.key === '{key}'" in palette, f"Palette must handle {key} key")
    require("data-palette-index" in palette, "Palette must track active index for keyboard nav")
    # Debounce + cancel superseded (RTK Query keeps latest arg).
    require("setTimeout" in palette and "setDebounced" in palette, "Palette must debounce the search query")
    require("skip: !open || trimmed.length < 1" in palette, "Palette must skip search when closed/empty")

    # --- Entity search uses backend /api/v1/search (not unbounded fan-out) ---
    for marker in [
        "globalSearch",
        "/api/v1/search",
        "q: query",
        "types",
        "limit",
        "Bearer",
        "normalizeSearch",
        "groups",
        "hits",
        "route",
        "useGlobalSearchQuery",
    ]:
        require(marker in search, f"search endpoint missing: {marker}")
    # No client-side fan-out over many list endpoints as a search implementation.
    require("/chats?" not in search and "/agents?" not in search and "/artifacts?" not in search,
            "Search must use /api/v1/search, not client fan-out over list endpoints")

    # --- Invocations: Cmd/Ctrl-K, sidebar Search button, mobile center button ---
    # Cmd/Ctrl-K desktop shortcut.
    require("metaKey || event.ctrlKey" in shell and "'k'" in shell,
            "AppShell must bind Cmd/Ctrl-K to open the palette")
    require("setPaletteOpen" in shell, "AppShell must own the palette open state")
    # Sidebar Search button opens palette (not a placeholder link).
    require('onClick={() => setPaletteOpen(true)}' in shell,
            "Sidebar Search button must open the palette")
    require("Command palette placeholder" not in shell,
            "Sidebar Search must not remain a placeholder link")
    # Mobile bottom-tab center button.
    require("shell-mobile-palette-button" in shell and "md:hidden" in shell,
            "AppShell must render a mobile center button (hidden on desktop) to open the palette")
    # Palette mounted + onNavigate routes via hash.
    require("<CommandPalette" in shell and "onNavigate={handlePaletteNavigate}" in shell,
            "AppShell must mount <CommandPalette> with a navigate handler")
    require("buildRouteHash(route" in shell,
            "Palette navigation must convert a route to a hash location")

    print("PASS: UI-12 command palette static")


if __name__ == "__main__":
    main()
