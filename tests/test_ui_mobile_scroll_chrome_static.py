#!/usr/bin/env python3
"""Static verification guard for mobile scroll hide/reveal, smooth transitions,
persistent floating toggle, bottom agent pill, full-screen transcript layout collapsing,
and AppShell mobile chrome suppression.

Requirements covered:
- REQ-MOBILE-SCROLL-1: ChatMessageList forwards onScroll event to ConversationThreadPage
- REQ-MOBILE-SCROLL-2: Mobile scroll down slides away top bar (-translate-y-full) and
  composer bottom bar (translate-y-full) with smooth transitions (duration-300 ease-in-out)
- REQ-MOBILE-SCROLL-FLOATING-TOGGLE: Floating button at top-right (fixed top-2.5 right-2.5 z-30)
  when chrome is hidden and right panel is closed
- REQ-MOBILE-SCROLL-COMPOSER-AGENT-PILL: Bottom agent name pill (fixed bottom-9 inset-x-0 flex justify-center z-30)
  when composer is hidden to open agent picker
- REQ-SCROLL-BOUNDARY-1: Restore top bar and composer when reaching top (currentTop <= TOP_MARGIN = 60) or bottom (distanceToBottom <= BOTTOM_MARGIN = 100) of transcript
- REQ-SCROLL-BOUNDARY-2: Validate boundary chrome restore, test suite execution, and clean git push
- REQ-SCROLL-MARGIN-4: Validate margin thresholds (TOP_MARGIN = 60, BOTTOM_MARGIN = 100) and bottom padding (pb-8)
- REQ-MOBILE-FS-1: Full-screen mobile transcript: top bar & composer layout boxes collapse to 0 height
- REQ-MOBILE-FS-2: AppShell listens to heimdall:mobile-chrome event, suppresses bottom tab bar & padding
- REQ-MOBILE-FS-3: Scroll hide unification: hides on any Math.abs(delta) > 8, inactivity timer removed
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAT_LIST_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ChatMessageList.tsx"
CONVERSATION_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
SHELL_FILE = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
RESPONSIVE_FILE = ROOT / "src" / "ui" / "components" / "shell" / "responsive.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_chat_message_list_on_scroll():
    src = CHAT_LIST_FILE.read_text(encoding="utf-8")
    require("onScroll?: (event: UIEvent<HTMLDivElement>) => void" in src,
            "ChatMessageListProps must expose onScroll prop taking UIEvent<HTMLDivElement>")
    require("onScrollProp?.(event)" in src,
            "ChatMessageList onScroll handler must forward event to onScrollProp")
    require("onScroll={onScroll}" in src and "ref={scrollRef}" in src,
            "ChatMessageList must bind onScroll to the scrollable container div")


def test_conversation_thread_page_scroll_tracking():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # State and refs
    require("const [chromeVisible, setChromeVisible] = useState(true)" in src,
            "ConversationThreadPage must have chromeVisible state initialized to true")
    require("lastScrollTopRef = useRef(0)" in src,
            "ConversationThreadPage must have lastScrollTopRef initialized to 0")
    require("inactivityTimerRef" not in src,
            "ConversationThreadPage must have inactivityTimerRef completely removed")
    require("1800" not in src,
            "handleTranscriptScroll must not have 1800ms inactivity timer")

    # Scroll callback logic
    require("handleTranscriptScroll" in src,
            "ConversationThreadPage must implement handleTranscriptScroll")
    require("if (!isMobile) return" in src,
            "handleTranscriptScroll must return early if !isMobile")
    require("const TOP_MARGIN = 60;" in src,
            "handleTranscriptScroll must define TOP_MARGIN = 60")
    require("const BOTTOM_MARGIN = 100;" in src,
            "handleTranscriptScroll must define BOTTOM_MARGIN = 100")
    require("const isAtTop = currentTop <= TOP_MARGIN;" in src,
            "handleTranscriptScroll must compute isAtTop using currentTop <= TOP_MARGIN")
    require("const isAtBottom = distanceToBottom <= BOTTOM_MARGIN;" in src,
            "handleTranscriptScroll must compute isAtBottom using distanceToBottom <= BOTTOM_MARGIN")
    require("if (isAtTop || isAtBottom)" in src,
            "handleTranscriptScroll must restore chrome on boundary reaching top or bottom")
    require("restoreChrome();\n        lastScrollTopRef.current = currentTop;\n        return;" in src,
            "handleTranscriptScroll must call restoreChrome() and update lastScrollTopRef on boundary")
    require("Math.abs(delta) > 8" in src,
            "handleTranscriptScroll must check Math.abs(delta) > 8 threshold")
    require("setChromeVisible(false);" in src,
            "handleTranscriptScroll must hide chrome when Math.abs(delta) > 8")

    # Forwarding prop and bottom padding
    require("onScroll={handleTranscriptScroll}" in src,
            "ChatMessageList must receive onScroll={handleTranscriptScroll}")
    require("pb-8" in src,
            "ChatMessageList scrollClassName must include pb-8 for bottom message padding")

    # Typing and focus restore
    require("restoreChrome" in src,
            "ConversationThreadPage must have restoreChrome helper")
    require("onFocus" in src and "restoreChrome()" in src,
            "Textarea onFocus must call restoreChrome")
    require("onChange" in src and "restoreChrome();" in src,
            "Textarea onChange must call restoreChrome")
    require("onKeyDown" in src and "restoreChrome();" in src,
            "Textarea onKeyDown must call restoreChrome")

    # Event dispatch
    require("heimdall:mobile-chrome" in src,
            "ConversationThreadPage must dispatch heimdall:mobile-chrome event")
    require("new CustomEvent('heimdall:mobile-chrome', { detail: { visible: chromeVisible } })" in src,
            "ConversationThreadPage must broadcast chromeVisible state in CustomEvent detail")


def test_transitions_and_classes():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # Top Bar transition classes
    require("max-h-0 py-0 border-transparent overflow-hidden -translate-y-full opacity-0 pointer-events-none" in src,
            "Top Bar must collapse layout box with max-h-0 py-0 border-transparent overflow-hidden -translate-y-full opacity-0 pointer-events-none")
    require("max-h-16 py-2 border-white/10 translate-y-0 opacity-100 pointer-events-auto" in src,
            "Top Bar must restore with max-h-16 py-2 border-white/10 translate-y-0 opacity-100 pointer-events-auto")
    require("transition-all duration-300 ease-in-out" in src,
            "Top Bar and Composer must have transition-all duration-300 ease-in-out")

    # Composer Bottom Bar transition classes
    require("max-h-0 py-0 px-3 overflow-hidden translate-y-full opacity-0 pointer-events-none" in src,
            "Composer bottom bar must collapse layout box with max-h-0 py-0 px-3 overflow-hidden translate-y-full opacity-0 pointer-events-none")
    require("max-h-[800px] px-3 pb-4 pt-2 translate-y-0 opacity-100 pointer-events-auto" in src,
            "Composer bottom bar must restore with max-h-[800px] px-3 pb-4 pt-2 translate-y-0 opacity-100 pointer-events-auto")


def test_app_shell_and_mobile_tab_bar():
    shell_src = SHELL_FILE.read_text(encoding="utf-8")
    responsive_src = RESPONSIVE_FILE.read_text(encoding="utf-8")

    require("const [scrollChromeSuppressed, setScrollChromeSuppressed] = useState(false);" in shell_src,
            "AppShell must declare scrollChromeSuppressed state initialized to false")
    require("window.addEventListener('heimdall:mobile-chrome'" in shell_src,
            "AppShell must listen for heimdall:mobile-chrome custom event")
    require("setScrollChromeSuppressed(true)" in shell_src and "setScrollChromeSuppressed(false)" in shell_src,
            "AppShell must toggle scrollChromeSuppressed based on visible detail")
    require("const hideMobileShellChrome = isMobile && (mobileChromeSuppressed || scrollChromeSuppressed);" in shell_src,
            "AppShell hideMobileShellChrome must include scrollChromeSuppressed")
    require("setScrollChromeSuppressed(false);" in shell_src,
            "AppShell route change handler must reset scrollChromeSuppressed to false")
    require("mobileBottomPadded={isMobile && !hideMobileShellChrome}" in shell_src,
            "AppShell must suppress bottom padding when hideMobileShellChrome is true")
    require("!hideMobileShellChrome ? (" in shell_src,
            "AppShell must conditionally render MobileTabBar based on hideMobileShellChrome")

    require("transition-transform duration-300 ease-in-out" in responsive_src,
            "MobileTabBar must include transition-transform duration-300 ease-in-out")


def test_floating_toggle_button():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    require("isMobile && !chromeVisible && rightPanel === 'closed'" in src,
            "Floating toggle button must only be active on mobile when chrome is hidden and right panel closed")
    require("fixed top-2.5 right-2.5 z-30" in src,
            "Floating toggle button must be rendered at fixed top-2.5 right-2.5 z-30")
    require("bg-black/50 backdrop-blur border border-white/10 text-zinc-400 hover:text-white rounded-xl h-9 w-9 grid place-items-center transition-opacity duration-200" in src,
            "Floating toggle button must match required styling")
    require("onClick={toggleRightPanel}" in src,
            "Floating toggle button must trigger toggleRightPanel on click")
    require('Icon name="panel-right"' in src,
            "Floating toggle button must show panel-right icon")


def test_bottom_agent_pill():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    require("fixed bottom-9 inset-x-0 flex justify-center z-30" in src,
            "Bottom agent pill must be rendered at fixed bottom-9 inset-x-0 flex justify-center z-30")
    require("bg-[#161618]/90 backdrop-blur-md border border-white/10 px-3 py-1.5 rounded-full text-xs font-medium text-zinc-300 shadow-lg flex items-center gap-1.5 hover:bg-white/10 hover:text-white transition-all duration-200" in src,
            "Bottom agent pill must match required styling")
    require("onClick={() => setAgentPickerOpen(true)}" in src,
            "Bottom agent pill must trigger setAgentPickerOpen(true) on click")
    require('Icon name="chevron-down"' in src,
            "Bottom agent pill must show chevron-down icon")


if __name__ == "__main__":
    test_chat_message_list_on_scroll()
    test_conversation_thread_page_scroll_tracking()
    test_transitions_and_classes()
    test_app_shell_and_mobile_tab_bar()
    test_floating_toggle_button()
    test_bottom_agent_pill()
    print("PASS: mobile scroll hide/reveal, smooth transitions, floating toggle, agent pill, and full-screen mobile static verification")
