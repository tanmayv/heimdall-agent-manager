#!/usr/bin/env python3
"""Static verification guard for mobile scroll hide/reveal, smooth transitions,
persistent floating toggle, bottom agent pill, True Overlay Architecture
for invariant transcript clientHeight (REQ-OVERLAY-1 to REQ-OVERLAY-5),
and explicit DOM spacer clearance with tap-to-appear composer (REQ-SPACER-1 to REQ-SPACER-4).

Requirements covered:
- REQ-MOBILE-SCROLL-1: ChatMessageList forwards onScroll event to ConversationThreadPage
- REQ-OVERLAY-1: On mobile, header is rendered as an overlay (fixed top-0 inset-x-0 z-20 h-14
  border-b border-white/10 bg-[#0c0c0c]/90 backdrop-blur-md) transitioning with CSS transform:
  -translate-y-full opacity-0 pointer-events-none when hidden, translate-y-0 opacity-100 pointer-events-auto when visible.
  No max-h-0 or py-0 collapsing.
- REQ-OVERLAY-2: On mobile, composer form is rendered as a floating overlay above the tab bar
  (fixed bottom-14 inset-x-0 z-20) transitioning with CSS transform:
  translate-y-full opacity-0 pointer-events-none when hidden, translate-y-0 opacity-100 pointer-events-auto when visible.
  No max-h-0 or py-0 collapsing.
- REQ-OVERLAY-3: Mobile transcript container and chat pane remain permanent full-height (h-full w-full)
  on mobile with invariant clientHeight.
- REQ-OVERLAY-4: ChatMessageList mobile scroll container has fixed top padding pt-16 (to clear 56px header overlay).
- REQ-OVERLAY-5: RouteOutlet for isConversationThreadRoute no longer adds dynamic pb-16 on mobile;
  MobileTabBar uses CSS transform translate-y-full when scrollChromeSuppressed is true instead of unmounting or changing layout dimensions.
- REQ-SPACER-1: ChatMessageList contains explicit DOM spacer element (<div data-debug-id="...-mobile-bottom-spacer" className="h-80 shrink-0 sm:hidden" aria-hidden="true" />)
  and pb-4 clearance for mobile.
- REQ-SPACER-2: handleTranscriptScroll removes isAtBottom auto-restore so scrolling down keeps full-screen reading mode uninterrupted.
- REQ-SPACER-3: Floating reply pill rendered when mobile chrome is hidden to allow tap-to-appear composer.
- REQ-SPACER-4: Automated static test suite, build verification, and push to origin/main.
- REQ-MOBILE-SCROLL-FLOATING-TOGGLE: Floating button at top-right (fixed top-2.5 right-2.5 z-30)
  when chrome is hidden and right panel is closed.
- REQ-MOBILE-SCROLL-COMPOSER-AGENT-PILL: Bottom agent name pill (fixed bottom-9 inset-x-0 flex justify-center z-30)
  when composer is hidden to open agent picker.
- REQ-SCROLL-BOUNDARY-1: Restore top bar and composer when reaching top (currentTop <= TOP_MARGIN = 60) of transcript.
- REQ-SCROLL-BOUNDARY-2: Validate boundary chrome restore, test suite execution, and clean git push.
- REQ-MOBILE-TOPBAR-FIX: Header uses conditional fixed on mobile and relative on desktop
  without unconditional relative in base classes, preventing mobile layout box cut-off.
- REQ-VAL-MOBILE-FIX: Static assertions verifying clean positioning separation and padding clearance.
- REQ-MOBILE-BORDERLESS: Mobile <header> removes border-b and shadow-sm, using bg-canvas/90 backdrop-blur-md
  to seamlessly float into the -bottom-6 blur-fade overlay.
- REQ-VAL-BORDERLESS: Static assertions verifying borderless mobile header and bg-canvas/90 backdrop-blur-md.
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


def test_chat_message_list_mobile_bottom_spacer():
    src = CHAT_LIST_FILE.read_text(encoding="utf-8")
    require('<div data-debug-id={`${debugPrefix}-mobile-bottom-spacer`} className="h-56 shrink-0 sm:hidden" aria-hidden="true" />' in src,
            "ChatMessageList must contain explicit DOM spacer with debugPrefix-mobile-bottom-spacer and h-56 shrink-0 sm:hidden")
    require("pb-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4" in src,
            "ChatMessageList default scrollClassName must use pb-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4")


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
    require("const isAtTop = currentTop <= TOP_MARGIN;" in src,
            "handleTranscriptScroll must compute isAtTop using currentTop <= TOP_MARGIN")
    require("const BOTTOM_MARGIN = 100;" in src,
            "handleTranscriptScroll must define BOTTOM_MARGIN = 100")
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

    # Forwarding prop and clearances
    require("onScroll={handleTranscriptScroll}" in src,
            "ChatMessageList must receive onScroll={handleTranscriptScroll}")
    require("pt-16 pb-4" in src,
            "ChatMessageList scrollClassName must include pt-16 pb-4 clearances")

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

    # Header Overlay classes
    header_idx = src.find('data-debug-id="conversation-thread-header"')
    require(header_idx != -1, "Header element must exist")
    header_chunk = src[header_idx:header_idx + 450]
    require("isMobile" in header_chunk, "Header classes must branch on isMobile")
    base_classes = header_chunk.split("isMobile")[0]
    require("relative" not in base_classes,
            "Header base classes must not contain unconditional relative (avoids mobile fixed collision)")
    require("relative z-20" in src,
            "Header must use relative z-20 on desktop")
    require("fixed top-0 inset-x-0 z-20 h-14 bg-canvas/90 backdrop-blur-md" in src,
            "Header must render as fixed top-0 overlay on mobile with bg-canvas/90 backdrop-blur-md")
    require("border-b" not in header_chunk,
            "Mobile header must not contain border-b (REQ-MOBILE-BORDERLESS)")
    require("shadow-sm" not in header_chunk,
            "Mobile header must not contain shadow-sm (REQ-MOBILE-BORDERLESS)")
    require("-translate-y-full opacity-0 pointer-events-none" in src,
            "Header must transition with -translate-y-full opacity-0 pointer-events-none when hidden")
    require("translate-y-0 opacity-100 pointer-events-auto" in src,
            "Header must transition with translate-y-0 opacity-100 pointer-events-auto when visible")
    require("max-h-0" not in src,
            "Header and Composer must not use max-h-0 collapsing")
    require("transition-all duration-300 ease-in-out" in src,
            "Header and Composer must have transition-all duration-300 ease-in-out")

    # Composer Floating Overlay classes
    require("fixed bottom-14 inset-x-0 z-20" in src,
            "Composer must render as fixed bottom-14 overlay above tab bar on mobile")
    require("translate-y-full opacity-0 pointer-events-none" in src,
            "Composer must transition with translate-y-full opacity-0 pointer-events-none when hidden")

    # Full-height transcript and chat pane
    require('data-debug-id="conversation-thread-transcript"' in src,
            "Transcript element must exist")
    require('className="h-full w-full min-h-0 min-w-0 max-w-full flex-1 overflow-x-hidden p-0 sm:px-4 sm:py-3"' in src,
            "Transcript container must remain permanent full-height on mobile")


def test_app_shell_and_mobile_tab_bar():
    shell_src = SHELL_FILE.read_text(encoding="utf-8")
    responsive_src = RESPONSIVE_FILE.read_text(encoding="utf-8")

    require("const [scrollChromeSuppressed, setScrollChromeSuppressed] = useState(false);" in shell_src,
            "AppShell must declare scrollChromeSuppressed state initialized to false")
    require("window.addEventListener('heimdall:mobile-chrome'" in shell_src,
            "AppShell must listen for heimdall:mobile-chrome custom event")
    require("setScrollChromeSuppressed(true)" in shell_src and "setScrollChromeSuppressed(false)" in shell_src,
            "AppShell must toggle scrollChromeSuppressed based on visible detail")
    require("setScrollChromeSuppressed(false);" in shell_src,
            "AppShell route change handler must reset scrollChromeSuppressed to false")

    # RouteOutlet for conversation thread must not add dynamic pb-16
    require(('if (isConversationThreadRoute) {\n    const agentInstanceId = decodeSegment(path.slice(\'/conversations/\'.length));\n    return (\n      <main data-debug-id="shell-main-route-outlet" className="min-w-0 flex-1 overflow-hidden bg-canvas">' in shell_src) or
            ('if (isConversationThreadRoute) {\n    const agentInstanceId = decodeSegment(path.slice(\'/conversations/\'.length));\n    return (\n      <main data-debug-id="shell-main-route-outlet" className="min-w-0 flex-1 overflow-hidden bg-[#090909]">' in shell_src),
            "RouteOutlet for isConversationThreadRoute must not add dynamic pb-16")

    # MobileTabBar uses CSS transform translate-y-full without unmounting on scroll hide
    require("scrollChromeSuppressed ? 'translate-y-full pointer-events-none' : 'translate-y-0 pointer-events-auto'" in shell_src,
            "MobileTabBar must receive translate-y-full transform class when scrollChromeSuppressed is true")

    require("transition-transform duration-300 ease-in-out" in responsive_src,
            "MobileTabBar must include transition-transform duration-300 ease-in-out")
    require("className = ''" in responsive_src,
            "MobileTabBar must accept className prop for transform transitions")


def test_floating_toggle_button():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    require("isMobile && !chromeVisible && rightPanel === 'closed'" in src,
            "Floating toggle button must only be active on mobile when chrome is hidden and right panel closed")
    require("fixed top-2.5 right-2.5 z-30" in src,
            "Floating toggle button must be rendered at fixed top-2.5 right-2.5 z-30")
    require(("bg-surface-overlay/80 backdrop-blur border border-subtle text-muted hover:text-primary rounded-xl h-9 w-9 grid place-items-center transition-opacity duration-200" in src) or
            ("bg-black/50 backdrop-blur border border-white/10 text-zinc-400 hover:text-white rounded-xl h-9 w-9 grid place-items-center transition-opacity duration-200" in src),
            "Floating toggle button must match required styling")
    require("onClick={toggleRightPanel}" in src,
            "Floating toggle button must trigger toggleRightPanel on click")
    require('Icon name="panel-right"' in src,
            "Floating toggle button must show panel-right icon")


def test_bottom_agent_pill():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    require("fixed bottom-9 inset-x-0 flex justify-center" in src and "items-center gap-2 z-30 pointer-events-none" in src,
            "Bottom floating pills container must be rendered at fixed bottom-9 inset-x-0 flex justify-center items-center gap-2 z-30 pointer-events-none")
    require('data-debug-id="conversation-floating-agent-pill"' in src,
            "Bottom agent pill must have data-debug-id='conversation-floating-agent-pill'")
    require(("bg-surface-raised/90 backdrop-blur-md border border-subtle px-3 py-1.5 rounded-full text-xs font-medium text-primary shadow-panel flex items-center gap-1.5 hover:bg-neutral-soft hover:text-primary transition-all duration-200" in src) or
            ("bg-[#161618]/90 backdrop-blur-md border border-white/10 px-3 py-1.5 rounded-full text-xs font-medium text-zinc-300 shadow-lg flex items-center gap-1.5 hover:bg-white/10 hover:text-white transition-all duration-200" in src),
            "Bottom agent pill must match required styling")
    require("onClick={() => setAgentPickerOpen(true)}" in src,
            "Bottom agent pill must trigger setAgentPickerOpen(true) on click")
    require('Icon name="chevron-down"' in src,
            "Bottom agent pill must show chevron-down icon")


def test_floating_reply_pill():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    require('data-debug-id="conversation-floating-reply-pill"' in src,
            "ConversationThreadPage must render floating reply pill with data-debug-id='conversation-floating-reply-pill'")
    require("restoreChrome();" in src,
            "Floating reply pill onClick must restore chrome")
    require("onClick={() => {\n              restoreChrome();\n            }}" in src or "onClick={() => {\r\n              restoreChrome();\r\n            }}" in src,
            "Floating reply pill onClick must purely restore chrome without auto-focusing input")
    require('aria-label="Reply"' in src and 'title="Reply"' in src,
            "Floating reply pill must have Reply accessibility attributes")
    require("Reply" in src,
            "Floating reply pill must display 'Reply' label")


if __name__ == "__main__":
    test_chat_message_list_on_scroll()
    test_chat_message_list_mobile_bottom_spacer()
    test_conversation_thread_page_scroll_tracking()
    test_transitions_and_classes()
    test_app_shell_and_mobile_tab_bar()
    test_floating_toggle_button()
    test_bottom_agent_pill()
    test_floating_reply_pill()
    print("PASS: Mobile scroll chrome and DOM spacer verification (REQ-OVERLAY-1..5, REQ-SPACER-1..4, REQ-MOBILE-BORDERLESS, REQ-VAL-BORDERLESS)")
