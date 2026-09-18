#!/usr/bin/env python3
"""Static verification for Memory Page scope combobox click-delegation and overlap fixes (CT-57).

Guarantees:
1. MemoryPage.tsx: Field component uses <div> instead of <label> to prevent browser
   synthetic click re-dispatch to the first form control (Projects combobox).
2. ScopeField.tsx: ScopeEditor map item uses <div> instead of <label> for dimension fields.
3. Combobox.tsx: Elevates z-index when open ('open ? \'z-20\' : \'z-auto\'') so open dropdowns
   stack cleanly over sibling grid controls.
4. Combobox.tsx: Calls stopPropagation() on popover container, search input, option selection,
   and chip remove buttons to prevent bubbling into ancestor click handlers.
"""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
MEMORY_PAGE = ROOT / "src" / "ui" / "components" / "memory" / "MemoryPage.tsx"
SCOPE_FIELD = ROOT / "src" / "ui" / "components" / "ui" / "patterns" / "ScopeField.tsx"
COMBOBOX = ROOT / "src" / "ui" / "components" / "ui" / "primitives" / "Combobox.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f"[-] FAIL: {message}")
        sys.exit(1)


def test_memory_page_field() -> None:
    src = MEMORY_PAGE.read_text(encoding="utf-8")
    require("function Field(" in src, "MemoryPage.tsx must define Field helper component")
    require(
        '<label className="block">' not in src,
        "MemoryPage.tsx must not use <label className=\"block\"> in Field (causes click re-dispatch to first form control)",
    )
    require(
        ('<div className="block">\n      <div className="mb-1 text-caption uppercase tracking-wide text-muted">{label}</div>\n      {children}\n    </div>' in src) or
        ('<div className="block">\n      <div className="mb-1 text-caption uppercase tracking-wide text-zinc-500">{label}</div>\n      {children}\n    </div>' in src),
        "MemoryPage.tsx Field component must render a <div> wrapper instead of <label>",
    )


def test_scope_field_editor() -> None:
    src = SCOPE_FIELD.read_text(encoding="utf-8")
    require("export function ScopeEditor(" in src, "ScopeField.tsx must export ScopeEditor component")
    require(
        "<label key={dim.key}" not in src,
        "ScopeField.tsx ScopeEditor must not wrap dimension controls in <label> (causes click re-dispatch)",
    )
    require(
        '<div key={dim.key} className="block">' in src,
        "ScopeField.tsx ScopeEditor must render each dimension field inside a <div key={dim.key} className=\"block\">",
    )


def test_combobox_elevation_and_event_propagation() -> None:
    src = COMBOBOX.read_text(encoding="utf-8")
    # 1. z-index elevation when open
    require(
        "open ? 'z-20' : 'z-auto'" in src,
        "Combobox.tsx must elevate container z-index when open (open ? 'z-20' : 'z-auto') to avoid grid overlap",
    )

    # 2. Stop propagation on chip remove
    require(
        "e.stopPropagation();" in src and "removeValue(v);" in src,
        "Combobox.tsx chip remove button must call e.stopPropagation()",
    )

    # 3. Stop propagation on popover container
    require(
        'data-debug-id={debugId ? `${debugId}-popover` : undefined}\n          onClick={(e) => e.stopPropagation()}'
        in src,
        "Combobox.tsx popover container must call e.stopPropagation() on click",
    )

    # 4. Stop propagation on search input
    require(
        'data-debug-id={debugId ? `${debugId}-search-input` : undefined}' in src
        and 'onClick={(e) => e.stopPropagation()}' in src,
        "Combobox.tsx search input must call e.stopPropagation() on click",
    )

    # 5. Stop propagation on option selection
    require(
        "e.stopPropagation();" in src and "selectOption(option);" in src,
        "Combobox.tsx option selection must call e.stopPropagation()",
    )


def main() -> None:
    test_memory_page_field()
    test_scope_field_editor()
    test_combobox_elevation_and_event_propagation()
    print("PASS: test_ui_memory_scope_combobox_static")


if __name__ == "__main__":
    main()
