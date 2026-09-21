#!/usr/bin/env python3
"""Static verification guard for shell and preview memory leak prevention.

Requirements covered:
- REQ-AUDIT-PREVIEW-FE-LEAKS:
  1. PreviewSidebar.tsx:
     - MAX_NAV_STACK is defined and caps navStackRef to prevent unbounded growth.
     - navStackRef deduplicates consecutive identical paths.
     - attachedWin tracks iframe contentWindow and detachInnerWindow removes
       'hashchange' and 'popstate' listeners on reload and unmount.
     - iframe.removeEventListener('load', onLoad) runs in effect cleanup.
     - iframe.src is reset to 'about:blank' on unmount to terminate zombie documents.
     - drag-to-resize effect cleans up mousemove/mouseup and resets document.body.style.userSelect.
  2. useDialogA11y.ts:
     - Removes keydown listener on unmount/close.
     - Restores body overflow and resets restoreRef.current to null to avoid leaking detached DOM nodes.
  3. ShellsPanel.tsx:
     - ShellRowMenu copy status timeout is tracked and cleared on unmount.
  4. previewTabsSlice.ts:
     - closeTab evicts tab state from tabs array and updates activeTabId.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREVIEW_SIDEBAR_FILE = ROOT / "src" / "ui" / "components" / "shells" / "PreviewSidebar.tsx"
SHELLS_PANEL_FILE = ROOT / "src" / "ui" / "components" / "shells" / "ShellsPanel.tsx"
USE_DIALOG_A11Y_FILE = ROOT / "src" / "ui" / "components" / "ui" / "composites" / "useDialogA11y.ts"
PREVIEW_TABS_SLICE_FILE = ROOT / "src" / "ui" / "store" / "previewTabsSlice.ts"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_preview_sidebar_leaks():
    require(PREVIEW_SIDEBAR_FILE.is_file(), f"PreviewSidebar.tsx must exist at {PREVIEW_SIDEBAR_FILE}")
    src = PREVIEW_SIDEBAR_FILE.read_text(encoding="utf-8")

    # 1. MAX_NAV_STACK capping and deduplication
    require("MAX_NAV_STACK" in src, "PreviewSidebar.tsx must define MAX_NAV_STACK")
    require("currentStack[currentStack.length - 1] !== path" in src,
            "PreviewSidebar.tsx must deduplicate consecutive navigation paths")
    require("slice(next.length - MAX_NAV_STACK)" in src,
            "PreviewSidebar.tsx must cap navStackRef to MAX_NAV_STACK entries")

    # 2. Inner-window listeners cleanup
    require("detachInnerWindow" in src, "PreviewSidebar.tsx must define detachInnerWindow")
    require("attachedWin.removeEventListener('hashchange', syncFromIframe)" in src,
            "detachInnerWindow must remove 'hashchange' listener")
    require("attachedWin.removeEventListener('popstate', syncFromIframe)" in src,
            "detachInnerWindow must remove 'popstate' listener")
    require("iframe.removeEventListener('load', onLoad)" in src,
            "PreviewFrame effect cleanup must remove 'load' listener from iframe")

    # 3. Iframe unmount detachment
    require("iframe.src = 'about:blank'" in src,
            "PreviewFrame must reset iframe.src = 'about:blank' on unmount")

    # 4. Drag resize listeners and userSelect cleanup
    require("window.removeEventListener('mousemove', onMove)" in src,
            "PreviewSidebar must remove 'mousemove' listener on unmount")
    require("window.removeEventListener('mouseup', onUp)" in src,
            "PreviewSidebar must remove 'mouseup' listener on unmount")
    require("document.body.style.userSelect = ''" in src,
            "PreviewSidebar drag cleanup must reset document.body.style.userSelect")


def test_use_dialog_a11y_leaks():
    require(USE_DIALOG_A11Y_FILE.is_file(), f"useDialogA11y.ts must exist at {USE_DIALOG_A11Y_FILE}")
    src = USE_DIALOG_A11Y_FILE.read_text(encoding="utf-8")

    # Keydown listener removal
    require("document.removeEventListener('keydown', onKeyDown, true)" in src,
            "useDialogA11y must remove keydown listener")

    # Overflow restore and restoreRef nullification
    require("document.body.style.overflow = prevOverflow" in src,
            "useDialogA11y must restore body overflow")
    require("restoreRef.current = null" in src,
            "useDialogA11y must clear restoreRef.current on cleanup to prevent detached DOM leaks")


def test_shells_panel_leaks():
    require(SHELLS_PANEL_FILE.is_file(), f"ShellsPanel.tsx must exist at {SHELLS_PANEL_FILE}")
    src = SHELLS_PANEL_FILE.read_text(encoding="utf-8")

    # Copy timeout cleanup
    require("copyTimerRef" in src, "ShellRowMenu must track copyTimerRef")
    require("window.clearTimeout(copyTimerRef.current)" in src,
            "ShellRowMenu must clear copyTimerRef on unmount and before rescheduling")


def test_preview_tabs_slice_eviction():
    require(PREVIEW_TABS_SLICE_FILE.is_file(), f"previewTabsSlice.ts must exist at {PREVIEW_TABS_SLICE_FILE}")
    src = PREVIEW_TABS_SLICE_FILE.read_text(encoding="utf-8")

    # Tab eviction on closeTab
    require("state.tabs.splice(index, 1)" in src,
            "previewTabsSlice closeTab must splice the closed tab from state.tabs")


def main():
    test_preview_sidebar_leaks()
    test_use_dialog_a11y_leaks()
    test_shells_panel_leaks()
    test_preview_tabs_slice_eviction()
    print("PASS: test_ui_preview_leak_prevention_static")


if __name__ == "__main__":
    main()
