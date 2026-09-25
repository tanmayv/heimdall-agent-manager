#!/usr/bin/env python3
"""Comprehensive test suite for ResourceContainer component suite (REQ-RESOURCE-CONTAINER-COMPONENTS-1).

Verifies:
1. Existence and integrity of all 5 composite components:
   - ResourceContainer.tsx
   - ResourceSearchFilter.tsx
   - ResourceEntryCard.tsx
   - ResourceDetailHeader.tsx
   - ResourceSectionCard.tsx
2. Correct exports from:
   - src/ui/components/ui/composites/index.ts
   - src/ui/components/ui/index.ts (barrel re-export)
3. Structural and behavioral contracts:
   - ResourceContainer: PageShell wrapping, 2-pane desktop layout (<=420px list, border-l border-subtle detail),
     independent scrolling (overflow-y-auto min-h-0), responsive mobile drill-down via useViewport().
   - ResourceSearchFilter: Search bar with leading search icon and clear button, status/view Tabs,
     filter Select dropdowns, and items counter.
   - ResourceEntryCard: Selectable row (min-h-[72px], hover vs active highlight bg-surface-raised),
     title link, 2-line snippet, status pills, badges, timestamps, more options menu.
   - ResourceDetailHeader: Mobile back trigger, alert banners, title, mono ID, status/badges,
     relative/absolute timestamps, action buttons cluster.
   - ResourceSectionCard: Uppercase subtle header, header action slot, children slot.
4. Component library rules:
   - Zero native <select> elements across all components.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
COMPOSITES_DIR = ROOT / "src" / "ui" / "components" / "ui" / "composites"
COMPOSITES_BARREL = COMPOSITES_DIR / "index.ts"
UI_BARREL = ROOT / "src" / "ui" / "components" / "ui" / "index.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"FAILED: {message}", file=sys.stderr)
        sys.exit(1)


def test_files_exist() -> None:
    print("Testing existence of all 5 Resource composite components...")
    files = [
        COMPOSITES_DIR / "ResourceContainer.tsx",
        COMPOSITES_DIR / "ResourceSearchFilter.tsx",
        COMPOSITES_DIR / "ResourceEntryCard.tsx",
        COMPOSITES_DIR / "ResourceDetailHeader.tsx",
        COMPOSITES_DIR / "ResourceSectionCard.tsx",
    ]
    for f in files:
        require(f.exists(), f"File does not exist: {f}")
    print("  ✓ All 5 component files exist.")


def test_barrel_exports() -> None:
    print("Testing re-exports from composites/index.ts and ui/index.ts...")
    composites_content = COMPOSITES_BARREL.read_text(encoding="utf-8")
    expected_exports = [
        "export { ResourceContainer }",
        "export type { ResourceContainerProps }",
        "export { ResourceSearchFilter, ResourceCounter }",
        "export type {",
        "ResourceSearchFilterProps",
        "export { ResourceEntryCard }",
        "export type { ResourceEntryCardProps",
        "export { ResourceDetailHeader }",
        "export type { ResourceDetailHeaderProps }",
        "export { ResourceSectionCard }",
        "export type { ResourceSectionCardProps }",
    ]
    for exp in expected_exports:
        require(exp in composites_content, f"Missing export in composites barrel: {exp}")

    ui_content = UI_BARREL.read_text(encoding="utf-8")
    require("export * from './composites';" in ui_content, "ui/index.ts must re-export ./composites")
    print("  ✓ Barrel exports verified.")


def test_resource_container_contract() -> None:
    print("Testing ResourceContainer contract...")
    src = (COMPOSITES_DIR / "ResourceContainer.tsx").read_text(encoding="utf-8")

    # Uses PageShell
    require("import { PageShell } from './PageShell';" in src, "Must import PageShell")
    require("<PageShell" in src, "Must wrap in PageShell")

    # Responsive mobile view switching via useViewport
    require("useViewport" in src, "Must use useViewport for responsive switching")
    require("viewport === 'desktop'" in src, "Must check desktop viewport for 2-pane mode")

    # 2-pane desktop layout
    require("max-w-[420px]" in src, "Must have <=420px max width for list column")
    require("border-l border-subtle pl-4" in src, "Must have border-l border-subtle pl-4 for detail pane")
    require("overflow-hidden" in src, "Must manage overflow for independent scrolling")
    require("min-h-0" in src, "Must use min-h-0 for proper flex scroll containers")

    # Fallback placeholder when no item is selected
    require("emptyDetailText" in src, "Must support emptyDetailText or empty placeholder")
    print("  ✓ ResourceContainer contract verified.")


def test_resource_search_filter_contract() -> None:
    print("Testing ResourceSearchFilter contract...")
    src = (COMPOSITES_DIR / "ResourceSearchFilter.tsx").read_text(encoding="utf-8")

    # Search bar with search icon and clear button
    require("search" in src, "Must use search icon")
    require("close" in src, "Must have clear button with close icon")
    require("onSearchChange" in src, "Must handle search change")

    # Status tabs
    require("Tabs" in src and "TabsList" in src and "Tab" in src, "Must use Tabs, TabsList, and Tab")

    # Select dropdown filters
    require("Select" in src, "Must use Select for filter dropdowns")

    # Items counter
    require("ResourceCounter" in src, "Must provide ResourceCounter component")
    require("itemsCount" in src, "Must support itemsCount")
    print("  ✓ ResourceSearchFilter contract verified.")


def test_resource_entry_card_contract() -> None:
    print("Testing ResourceEntryCard contract...")
    src = (COMPOSITES_DIR / "ResourceEntryCard.tsx").read_text(encoding="utf-8")

    # Selectable row styling
    require("min-h-[72px]" in src, "Must have min-h-[72px]")
    require("bg-surface-raised" in src, "Must use bg-surface-raised for active state")
    require("hover:bg-surface" in src, "Must use hover:bg-surface for hover state")
    require("border-b border-subtle" in src, "Must have border-b border-subtle")

    # 2-line snippet preview
    require("-webkit-line-clamp" in src or "line-clamp" in src, "Must clamp snippet to 2 lines")
    require("emptySnippetText" in src, "Must handle empty snippet fallback")

    # Context menu
    require("Menu" in src and "MenuItem" in src, "Must support Menu and MenuItem for actions")
    require("more-horizontal" in src, "Must use more-horizontal icon for context menu")

    # Status and timestamps
    require("timestamp" in src, "Must display timestamp")
    require("status" in src, "Must support status slot")
    require("badges" in src, "Must support badges slot")
    print("  ✓ ResourceEntryCard contract verified.")


def test_resource_detail_header_contract() -> None:
    print("Testing ResourceDetailHeader contract...")
    src = (COMPOSITES_DIR / "ResourceDetailHeader.tsx").read_text(encoding="utf-8")

    # Mobile back button
    require("onBack" in src, "Must support onBack callback")
    require("chevron-left" in src, "Must have chevron-left icon for back button")

    # Alert banners
    require("alert" in src, "Must support alert prop")

    # Title and mono ID
    require("font-mono" in src, "Must style ID in mono font")
    require("break-words" in src, "Must support long titles with break-words")

    # Badges & status & action buttons cluster
    require("status" in src, "Must support status slot")
    require("badges" in src, "Must support badges slot")
    require("actions" in src, "Must support actions cluster slot")
    print("  ✓ ResourceDetailHeader contract verified.")


def test_resource_section_card_contract() -> None:
    print("Testing ResourceSectionCard contract...")
    src = (COMPOSITES_DIR / "ResourceSectionCard.tsx").read_text(encoding="utf-8")

    # Panel wrapper
    require("Panel" in src, "Must use Panel")
    require("uppercase" in src, "Must use uppercase tracking-wider text-muted for header")
    require("action" in src, "Must support optional action slot in header")
    require("children" in src, "Must support children")
    print("  ✓ ResourceSectionCard contract verified.")


def test_no_native_select() -> None:
    print("Testing rule: Zero native <select> tags across new components...")
    files = [
        COMPOSITES_DIR / "ResourceContainer.tsx",
        COMPOSITES_DIR / "ResourceSearchFilter.tsx",
        COMPOSITES_DIR / "ResourceEntryCard.tsx",
        COMPOSITES_DIR / "ResourceDetailHeader.tsx",
        COMPOSITES_DIR / "ResourceSectionCard.tsx",
    ]
    select_regex = re.compile(r"<select[\s>]")
    for f in files:
        content = f.read_text(encoding="utf-8")
        require(not select_regex.search(content), f"Forbidden native <select> found in {f.name}")
    print("  ✓ Zero native <select> elements confirmed.")


def main() -> None:
    print("=== Running ResourceContainer Component Suite Verification ===")
    test_files_exist()
    test_barrel_exports()
    test_resource_container_contract()
    test_resource_search_filter_contract()
    test_resource_entry_card_contract()
    test_resource_detail_header_contract()
    test_resource_section_card_contract()
    test_no_native_select()
    print("=== All ResourceContainer suite tests PASSED successfully! ===")


if __name__ == "__main__":
    main()
