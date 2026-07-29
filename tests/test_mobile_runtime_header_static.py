#!/usr/bin/env python3
"""Static regression for mobile conversation header and runtime controls.

Locks in: contextual mobile title, runtime popover dismissal, mobile sheet
instead of clipped popover, and visible/touch-friendly task-chain action.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
THREAD = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")
SHELL = (ROOT / "src/ui/components/shell/AppShell.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# Mobile top bar should use active conversation title from summary data instead
# of the generic routeTitle('/conversations/:id') => "Conversation" string.
for marker in [
    "function routeMobileTitle",
    "path.startsWith('/conversations/')",
    "displayConversationTitle(conversation)",
    "const mobileRouteTitle = useMemo(() => routeMobileTitle(path, conversations)",
    "<MobileTopBar title={mobileRouteTitle}",
]:
    require(marker in SHELL, f"AppShell missing contextual mobile title marker: {marker}")
require("<MobileTopBar title={routeTitle(path)}" not in SHELL,
        "mobile top bar must not use generic routeTitle for conversation detail routes")

# Runtime menu dismissal: outside pointer/touch, focus leaving, Escape, action
# selection all close the menu without blocking interaction inside.
for marker in [
    "useRef",
    "runtimeMenuRef",
    "runtimeMenuButtonRef",
    "document.addEventListener('mousedown', onPointerDown)",
    "document.addEventListener('touchstart', onPointerDown",
    "document.addEventListener('focusin', onFocusIn)",
    "document.addEventListener('keydown', onKeyDown)",
    "event.key === 'Escape'",
    "!isInsideRuntimeMenu(event.target)",
    "setRuntimeMenuOpen(false); void applyReconfigure();",
    "setRuntimeMenuOpen(false); void doRestart();",
]:
    require(marker in THREAD, f"runtime menu missing dismissal marker: {marker}")

# Mobile renders a viewport-safe sheet/dialog with backdrop and close button;
# desktop keeps a non-mobile popover.
for marker in [
    "const isMobile = viewport === 'mobile'",
    "runtimeMenuOpen && !isMobile",
    'data-debug-id="conversation-runtime-menu" role="menu"',
    "runtimeMenuOpen && isMobile",
    'data-debug-id="conversation-runtime-mobile-sheet"',
    'role="dialog"',
    'aria-modal="true"',
    "max-h-[86vh]",
    "overflow-y-auto",
    "onPointerDown={(event) => { if (event.target === event.currentTarget) setRuntimeMenuOpen(false); }}",
    'data-debug-id="conversation-runtime-mobile-sheet-close"',
]:
    require(marker in THREAD, f"runtime mobile sheet missing marker: {marker}")

# Header/actions: actions wrap on mobile, touch targets remain visible, and the
# task-chain button is not hidden behind overflow.
for marker in [
    'data-debug-id="conversation-thread-mobile-actions"',
    "flex-wrap",
    "sm:flex-nowrap",
    "min-h-10 shrink-0 rounded-xl",
    'data-debug-id="taskchain-overview-toggle-btn"',
    "Task Chain",
]:
    require(marker in THREAD, f"mobile header/task-chain visibility marker missing: {marker}")

print("PASS: mobile runtime sheet, dismissal, contextual title, and task-chain action static checks")
