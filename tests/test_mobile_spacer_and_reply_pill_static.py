#!/usr/bin/env python3
"""Static regression tests for explicit DOM spacer removal, unified scroll flow,
tap-to-appear composer removal, and right sidebar tab chain persistence.

Requirements covered:
- REQ-SIMPLIFY-LAYOUT-1 & REQ-SIMPLIFY-SCROLL-4:
  * ChatMessageList contains no debugPrefix-mobile-bottom-spacer.
  * ChatMessageList accepts footer prop and renders inside scroll container.
- REQ-SIMPLIFY-GUTTER-3:
  * AgentActivityBubbles renders nothing when empty (no reserved empty space).
- REQ-SIMPLIFY-COMPOSER-2:
  * Composer is positioned in flow at the bottom (no fixed bottom-14 on mobile).
- REQ-SIMPLIFY-SCROLL-4:
  * No floating reply pill, agent pill, or floating panel toggle pill in ConversationThreadPage.tsx.
  * Mobile scroll chrome hide/reveal and translation transforms removed.
- REQ-CHAIN-SIDEBAR-PERSIST-5:
  * Right sidebar tab persistence functions support chainId.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAT_LIST = (ROOT / "src/ui/components/chat/ChatMessageList.tsx").read_text(encoding="utf-8")
THREAD_PAGE = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")
BUBBLES = (ROOT / "src/ui/components/chat/AgentActivityBubbles.tsx").read_text(encoding="utf-8")
PERSISTENCE = (ROOT / "src/ui/utils/clientPersistence.ts").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# 1. ChatMessageList contains no debugPrefix-mobile-bottom-spacer
require(
    'data-debug-id={`${debugPrefix}-mobile-bottom-spacer`}' not in CHAT_LIST,
    "ChatMessageList must contain no debugPrefix-mobile-bottom-spacer"
)
require(
    "footer?: ReactNode" in CHAT_LIST,
    "ChatMessageList must accept footer prop"
)
require(
    "{footer}" in CHAT_LIST,
    "ChatMessageList must render footer inside scroll container"
)
require(
    "pt-16 pb-4" not in CHAT_LIST,
    "ChatMessageList default scrollClassName must not have artificial pt-16 overlay padding"
)

# 2. AgentActivityBubbles renders nothing when empty (no reserved empty space)
require(
    "if (visible.length === 0) return null;" in BUBBLES,
    "AgentActivityBubbles must return null when visible.length === 0"
)
require(
    "// Reserved fixed-height gutter: ALWAYS rendered (even when empty)" not in BUBBLES,
    "AgentActivityBubbles must have reserved empty gutter comment/behavior removed"
)

# 3. Composer is positioned in flow at the bottom (no fixed bottom-14 on mobile)
require(
    'className="w-full max-w-4xl mx-auto px-3 sm:px-0 py-4"' in THREAD_PAGE,
    "Composer form must use normal in-flow container styling at the bottom"
)
require(
    "fixed bottom-14 inset-x-0 z-20" not in THREAD_PAGE,
    "Composer must not use fixed bottom-14 overlay on mobile"
)

# 4. No floating reply pill, agent pill, or floating panel toggle pill in ConversationThreadPage.tsx
require(
    'data-debug-id="conversation-floating-reply-pill"' not in THREAD_PAGE,
    "Floating reply pill must not be present in ConversationThreadPage.tsx"
)
require(
    'data-debug-id="conversation-floating-agent-pill"' not in THREAD_PAGE,
    "Floating agent pill must not be present in ConversationThreadPage.tsx"
)
require(
    'data-debug-id="conversation-floating-panel-toggle-btn"' not in THREAD_PAGE,
    "Floating panel toggle button must not be present in ConversationThreadPage.tsx"
)
require(
    "handleTranscriptScroll" not in THREAD_PAGE,
    "handleTranscriptScroll must be removed from ConversationThreadPage.tsx"
)
require(
    "chromeVisible" not in THREAD_PAGE,
    "chromeVisible state must be removed from ConversationThreadPage.tsx"
)
require(
    "restoreChrome" not in THREAD_PAGE,
    "restoreChrome helper must be removed from ConversationThreadPage.tsx"
)

# 5. Right sidebar tab persistence functions support chainId
require(
    "heimdall:sidebar:tab:chain:" in PERSISTENCE,
    "clientPersistence must define heimdall:sidebar:tab:chain: key format"
)
require(
    "heimdall:sidebar:open:chain:" in PERSISTENCE,
    "clientPersistence must define heimdall:sidebar:open:chain: key format"
)
require(
    "export function readRightSidebarTab" in PERSISTENCE and "chainId" in PERSISTENCE,
    "readRightSidebarTab must support chainId"
)
require(
    "export function writeRightSidebarTab" in PERSISTENCE and "chainId" in PERSISTENCE,
    "writeRightSidebarTab must support chainId"
)
require(
    "export function readRightSidebarOpen" in PERSISTENCE and "chainId" in PERSISTENCE,
    "readRightSidebarOpen must support chainId"
)
require(
    "export function writeRightSidebarOpen" in PERSISTENCE and "chainId" in PERSISTENCE,
    "writeRightSidebarOpen must support chainId"
)
require(
    "prevChainIdRef" in THREAD_PAGE,
    "ConversationThreadPage must track prevChainIdRef to preserve tab on instance switch within same chain"
)

print("ALL STATIC REGRESSION TESTS PASSED (test_mobile_spacer_and_reply_pill_static)")
