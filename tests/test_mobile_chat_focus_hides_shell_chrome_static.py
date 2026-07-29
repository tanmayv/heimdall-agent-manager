#!/usr/bin/env python3
"""Static checks for hiding mobile shell chrome while chat composers are focused."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = (ROOT / "src/ui/components/shell/AppShell.tsx").read_text(encoding="utf-8")
THREAD = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")
CHAT_COMPOSER = (ROOT / "src/ui/components/chat/ChatComposer.tsx").read_text(encoding="utf-8")
LAUNCH = (ROOT / "src/ui/components/chat/ConversationLaunchComposer.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# Chat inputs/composers opt in to chrome suppression while focused.
for marker, source_name, source in [
    ('data-debug-id="conversation-composer-shell" data-mobile-shell-chrome="hide-on-focus"', 'conversation thread composer', THREAD),
    ('data-mobile-shell-chrome="hide-on-focus"', 'shared ChatComposer', CHAT_COMPOSER),
    ('data-debug-id="new-convo-input" data-mobile-shell-chrome="hide-on-focus"', 'new conversation textarea', LAUNCH),
]:
    require(marker in source, f"{source_name} missing mobile shell chrome suppression marker: {marker}")

# AppShell tracks focus only on mobile and restores chrome when focus leaves.
for marker in [
    'const [mobileChromeSuppressed, setMobileChromeSuppressed] = useState(false);',
    'if (!isMobile) { setMobileChromeSuppressed(false); return; }',
    'focusSuppressesChrome',
    "closest?.('[data-mobile-shell-chrome=\"hide-on-focus\"]')",
    "document.addEventListener('focusin', onFocusIn)",
    "document.addEventListener('focusout', onFocusOut)",
    'window.setTimeout(updateFromActiveElement, 0)',
    'document.removeEventListener(\'focusin\', onFocusIn)',
    'document.removeEventListener(\'focusout\', onFocusOut)',
    'const hideMobileShellChrome = isMobile && mobileChromeSuppressed;',
]:
    require(marker in SHELL, f"AppShell missing mobile focus tracking marker: {marker}")

# Top and bottom mobile chrome render only when not suppressed; route padding also
# disappears so the chat composer can use the space previously reserved for tabs.
for marker in [
    'isMobile && !hideMobileShellChrome ? (',
    '<MobileTopBar title={mobileRouteTitle} onOpenDrawer={() => setDrawerOpen(true)} />',
    'mobileBottomPadded={isMobile && !hideMobileShellChrome}',
    '{!hideMobileShellChrome ? (\n        <MobileTabBar',
]:
    require(marker in SHELL, f"AppShell missing conditional mobile chrome render marker: {marker}")
require('mobileBottomPadded={isMobile} conversations={conversations}' not in SHELL,
        "RouteOutlet must not keep bottom tab padding while mobile chrome is hidden")

print("PASS: mobile chat focus hides shell chrome static checks")
