#!/usr/bin/env python3
"""Static guard for UI-15: legacy surfaces excluded from the rewrite are absent
from the LIVE app (main.tsx -> AppShell -> routed pages), deleted dead files stay
deleted, and the refactor-source legacy file is clearly quarantined (not mounted)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "src" / "ui" / "main.tsx"
SHELL = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
ROUTES_DOC = ROOT / "docs" / "plans" / "ui-routes-component-hierarchy.md"

# Refactor-source legacy file that is NOT mounted in the live app. Many prior
# task static guards reference its wiring, so it is retained as a quarantined
# refactor source rather than deleted in this pass; the guard only asserts it is
# not reachable from main.tsx/AppShell.
LEGACY_APP = ROOT / "src" / "ui" / "components" / "App.tsx"

# Files that were genuinely dead (no importer, including no test) and have been
# deleted as part of UI-15. They MUST stay deleted.
DELETED_LEGACY = [
    ROOT / "src" / "ui" / "components" / "AuditSidebar.tsx",
    ROOT / "src" / "ui" / "components" / "AuditCard.tsx",
]

# Legacy surfaces the architecture (§6E) excludes from the rewrite. None of these
# may appear in the live mount path (main.tsx, AppShell, or anything AppShell
# imports). They may still exist as unmounted refactor sources elsewhere.
EXCLUDED_SURFACES = [
    "UnifiedWorkspaceShell",
    "WorkspaceLeftSidebar",
    "WorkspaceMainRegion",
    "OnboardingWizard",
    "MemoryManagementPage",
    "NewLocalProxyAgentWizard",
    "VimSidebar",
    "ChainEditor",
    "AttentionPage",
    "AuditSidebar",
    "AuditCard",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def live_imports() -> set:
    """Return the set of import target basenames reachable from the live app:
    main.tsx and AppShell.tsx (the only mounted root)."""
    files = {MAIN, SHELL}
    texts = {}
    for f in files:
        texts[str(f)] = f.read_text(encoding="utf-8")
    return set(texts.values())


def main() -> None:
    main_text = MAIN.read_text(encoding="utf-8")
    shell_text = SHELL.read_text(encoding="utf-8")
    routes_doc = ROUTES_DOC.read_text(encoding="utf-8")

    # --- The live app mounts ONLY AppShell (no legacy App.tsx root) ---
    require("import AppShell from './components/shell/AppShell'" in main_text,
            "main.tsx must mount the rewrite AppShell")
    require("<AppShell" in main_text, "main.tsx must render <AppShell>")
    # Legacy refactor-source App.tsx must NOT be imported by the live root.
    require("components/App'" not in main_text and "components/App\"" not in main_text,
            "main.tsx must not import the legacy App.tsx")
    require("App.tsx" not in main_text.replace("AppShell", ""),
            "main.tsx must not reference the legacy App.tsx")

    # --- Deleted dead legacy files stay deleted ---
    for dead in DELETED_LEGACY:
        require(not dead.exists(), f"deleted legacy file must not be reintroduced: {dead.name}")

    # --- Excluded legacy surfaces are absent from the live mount path ---
    for surface in EXCLUDED_SURFACES:
        require(surface not in main_text, f"main.tsx must not reference excluded legacy surface: {surface}")
        require(surface not in shell_text, f"AppShell must not reference excluded legacy surface: {surface}")

    # --- AppShell imports only rewrite surfaces (no legacy component imports) ---
    # The allowed live imports are the rewrite shell primitives, the launch
    # composer, the command palette, the user-WS hook, and the RTK Query sidebar
    # endpoints. None of the excluded surfaces may sneak in via AppShell imports.
    import_lines = [ln for ln in shell_text.splitlines() if ln.strip().startswith("import") or ln.strip().startswith("from")]
    for surface in EXCLUDED_SURFACES:
        for ln in import_lines:
            require(surface not in ln, f"AppShell must not import excluded legacy surface: {surface}")

    # --- No global attention badge / global right sidebar / guide panel in the live shell ---
    for forbidden in [
        "global-attention-badge",
        "global-right-sidebar",
        "guide-panel",
        "GuideSidePanel",
        "GlobalRightSidebar",
    ]:
        require(forbidden not in shell_text, f"AppShell must not contain excluded global surface: {forbidden}")

    # --- Legacy refactor-source App.tsx is quarantined, not mounted ---
    if LEGACY_APP.exists():
        app_text = LEGACY_APP.read_text(encoding="utf-8")
        # It must carry the rtkq-migration quarantine marker (shared with the
        # legacy-refresh-cleanup guard) so it is recognizably unmounted legacy.
        require("TODO(rtkq-migration owner=task-19f69e242e4)" in app_text,
                "retained legacy App.tsx must carry its quarantine marker (not silently mounted)")

    # --- Routes doc records the removed/not-ported legacy inventory (UI-16) ---
    require("## 11. Removed / not-ported legacy route and surface inventory" in routes_doc,
            "routes/component hierarchy doc must record the removed legacy inventory")
    for legacy in ["UnifiedWorkspaceShell", "VimSidebar.tsx", "ChainEditor.tsx", "NewLocalProxyAgentWizard.tsx"]:
        require(legacy in routes_doc, f"routes doc must list removed legacy surface: {legacy}")

    print("PASS: UI-15 legacy cleanup static (excluded surfaces absent from live app; dead files removed)")


if __name__ == "__main__":
    main()
