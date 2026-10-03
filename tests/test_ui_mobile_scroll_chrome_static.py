#!/usr/bin/env python3
"""Static verification guard for simplified conversation layout, unified scroll flow,
in-flow bottom composer, removal of mobile scroll chrome hiding/floating pills,
and chain-level right sidebar tab persistence.

Requirements covered:
- REQ-SIMPLIFY-LAYOUT-1 & REQ-SIMPLIFY-SCROLL-4:
  * ChatMessageList contains no debugPrefix-mobile-bottom-spacer.
  * ChatMessageList accepts footer prop and renders inside scroll container.
  * ChatMessageList forwards onScroll event to container div.
  * Artificial pt-16 overlay padding is removed.
- REQ-SIMPLIFY-GUTTER-3:
  * AgentActivityBubbles returns null when empty (no reserved empty space).
- REQ-SIMPLIFY-COMPOSER-2:
  * Composer is positioned in flow at the bottom (no fixed bottom-14 on mobile).
  * No keyboardAwareBottomPx on composer form.
  * Loading indicator, bubbles, shell runs, and composer all scroll together in document flow.
- REQ-SIMPLIFY-SCROLL-4:
  * Mobile scroll chrome hide/reveal removed (no handleTranscriptScroll, chromeVisible, restoreChrome).
  * No floating reply pill, agent pill, or floating panel toggle pill in ConversationThreadPage.tsx.
  * Header stays at top of Col 1 with sticky top-0 z-20 without scroll translation.
- REQ-CHAIN-SIDEBAR-PERSIST-5:
  * Right sidebar tab persistence functions support chainId.
  * ConversationThreadPage preserves right panel tab on instance switch within same chain.
- REQ-MOBILE-SLIM-SIDEBAR-11:
  * AppShell removes MobileTabBar and mobileBottomPadded completely.
  * AppShell implements slim mobile left sidebar with isEffectiveCollapsed and shell-sidebar-collapse-toggle.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAT_LIST_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ChatMessageList.tsx"
CONVERSATION_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
BUBBLES_FILE = ROOT / "src" / "ui" / "components" / "chat" / "AgentActivityBubbles.tsx"
SHELL_FILE = ROOT / "src" / "ui" / "components" / "shell" / "AppShell.tsx"
RESPONSIVE_FILE = ROOT / "src" / "ui" / "components" / "shell" / "responsive.tsx"
PERSISTENCE_FILE = ROOT / "src" / "ui" / "utils" / "clientPersistence.ts"


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


def test_chat_message_list_unified_scroll():
    src = CHAT_LIST_FILE.read_text(encoding="utf-8")
    require('data-debug-id={`${debugPrefix}-mobile-bottom-spacer`}' not in src,
            "ChatMessageList must contain no debugPrefix-mobile-bottom-spacer")
    require("footer?: ReactNode" in src,
            "ChatMessageList must accept footer prop")
    require("{footer}" in src,
            "ChatMessageList must render footer inside scroll container")
    require("pt-16 pb-4" not in src,
            "ChatMessageList default scrollClassName must not have artificial pt-16 overlay padding")


def test_agent_activity_bubbles_gutter():
    src = BUBBLES_FILE.read_text(encoding="utf-8")
    require("if (visible.length === 0) return null;" in src,
            "AgentActivityBubbles must return null when visible.length === 0")
    require("// Reserved fixed-height gutter: ALWAYS rendered (even when empty)" not in src,
            "AgentActivityBubbles must not reserve fixed-height gutter when empty")


def test_conversation_thread_page_scroll_flow():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # In-flow bottom composer
    require('className="w-full max-w-4xl mx-auto px-3 sm:px-0 py-4"' in src,
            "Composer form must be in normal document flow at the bottom")
    require("fixed bottom-14 inset-x-0 z-20" not in src,
            "Composer must not be rendered as fixed bottom-14 overlay on mobile")
    require("keyboardAwareBottomPx" not in src,
            "Composer must not use keyboardAwareBottomPx")

    # Unified footer passed into ChatMessageList
    require("footer={(" in src and "<AgentActivityBubbles instanceId={agentInstanceId} />" in src and "{renderComposer()}" in src,
            "ConversationThreadPage must pass bubbles and composer as footer into ChatMessageList scroll flow")

    # Mobile scroll smartness completely removed
    require("handleTranscriptScroll" not in src,
            "handleTranscriptScroll must be removed from ConversationThreadPage")
    require("chromeVisible" not in src,
            "chromeVisible state must be removed from ConversationThreadPage")
    require("restoreChrome" not in src,
            "restoreChrome must be removed from ConversationThreadPage")
    require("new CustomEvent('heimdall:mobile-chrome'" not in src,
            "ConversationThreadPage must not dispatch heimdall:mobile-chrome scroll events")


def test_no_floating_pills():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")
    require('data-debug-id="conversation-floating-reply-pill"' not in src,
            "Floating reply pill must not be rendered")
    require('data-debug-id="conversation-floating-agent-pill"' not in src,
            "Floating agent pill must not be rendered")
    require('data-debug-id="conversation-floating-panel-toggle-btn"' not in src,
            "Floating panel toggle button must not be rendered")


def test_header_sticky_and_transcript():
    src = CONVERSATION_FILE.read_text(encoding="utf-8")
    require('data-debug-id="conversation-thread-header"' in src,
            "Header element must exist")
    header_idx = src.find('data-debug-id="conversation-thread-header"')
    header_chunk = src[header_idx:header_idx + 450]
    require("sticky top-0 z-20" in header_chunk,
            "Header must use sticky top-0 z-20")
    require("-translate-y-full" not in header_chunk,
            "Header must not hide or translate away on scroll")
    require('data-debug-id="conversation-thread-transcript"' in src,
            "Transcript element must exist")


def test_app_shell_and_mobile_slim_sidebar():
    shell_src = SHELL_FILE.read_text(encoding="utf-8")

    require('data-debug-id="shell-main-route-outlet"' in shell_src,
            "AppShell must render shell-main-route-outlet")
    require("<MobileTabBar" not in shell_src,
            "AppShell must not render MobileTabBar")
    require("mobileBottomPadded" not in shell_src,
            "AppShell must not use or define mobileBottomPadded")
    require("isEffectiveCollapsed" in shell_src,
            "AppShell must implement slim mobile left sidebar with isEffectiveCollapsed")
    require('data-debug-id="shell-sidebar-collapse-toggle"' in shell_src,
            "AppShell must provide a toggle button to expand/collapse sidebar")
    require("min-h-11" in shell_src,
            "NavItem must enforce touch-friendly min-h-11 targets")


def test_right_sidebar_tab_chain_persistence():
    persistence_src = PERSISTENCE_FILE.read_text(encoding="utf-8")
    thread_src = CONVERSATION_FILE.read_text(encoding="utf-8")

    require("heimdall:sidebar:tab:chain:" in persistence_src,
            "clientPersistence must support heimdall:sidebar:tab:chain: storage key")
    require("heimdall:sidebar:open:chain:" in persistence_src,
            "clientPersistence must support heimdall:sidebar:open:chain: storage key")
    require("export function readRightSidebarTab" in persistence_src and "chainId" in persistence_src,
            "readRightSidebarTab must accept chainId")
    require("export function writeRightSidebarTab" in persistence_src and "chainId" in persistence_src,
            "writeRightSidebarTab must accept chainId")
    require("export function readRightSidebarOpen" in persistence_src and "chainId" in persistence_src,
            "readRightSidebarOpen must accept chainId")
    require("export function writeRightSidebarOpen" in persistence_src and "chainId" in persistence_src,
            "writeRightSidebarOpen must accept chainId")
    require("prevChainIdRef" in thread_src,
            "ConversationThreadPage must use prevChainIdRef to preserve tab on same-chain instance switch")


if __name__ == "__main__":
    test_chat_message_list_on_scroll()
    test_chat_message_list_unified_scroll()
    test_agent_activity_bubbles_gutter()
    test_conversation_thread_page_scroll_flow()
    test_no_floating_pills()
    test_header_sticky_and_transcript()
    test_app_shell_and_mobile_slim_sidebar()
    test_right_sidebar_tab_chain_persistence()
    print("PASS: Simplified conversation layout and chain tab persistence verification (REQ-SIMPLIFY-LAYOUT-1, REQ-SIMPLIFY-COMPOSER-2, REQ-SIMPLIFY-GUTTER-3, REQ-SIMPLIFY-SCROLL-4, REQ-CHAIN-SIDEBAR-PERSIST-5, REQ-MOBILE-SLIM-SIDEBAR-11)")
