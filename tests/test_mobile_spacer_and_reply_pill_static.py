#!/usr/bin/env python3
"""Static regression tests for explicit DOM spacer clearance and tap-to-appear composer on mobile.

Requirements:
- REQ-SPACER-1: ChatMessageList contains explicit DOM spacer with h-80 shrink-0 sm:hidden.
- REQ-SPACER-2: handleTranscriptScroll removes isAtBottom auto-restore so scrolling down keeps full-screen reading mode.
- REQ-SPACER-3: Floating reply pill rendered when mobile chrome is hidden to allow tap-to-appear.
- scrollClassName uses pb-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAT_LIST = (ROOT / "src/ui/components/chat/ChatMessageList.tsx").read_text(encoding="utf-8")
THREAD_PAGE = (ROOT / "src/ui/components/chat/ConversationThreadPage.tsx").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# REQ-SPACER-1: ChatMessageList explicit DOM spacer
require(
    '<div data-debug-id={`${debugPrefix}-mobile-bottom-spacer`} className="h-80 shrink-0 sm:hidden" aria-hidden="true" />' in CHAT_LIST,
    "ChatMessageList must contain explicit DOM spacer with debugPrefix-mobile-bottom-spacer and h-80 shrink-0 sm:hidden"
)

# REQ-SPACER-1: scrollClassName padding-bottom clearance
require(
    "pb-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4" in CHAT_LIST,
    "ChatMessageList default scrollClassName must use pb-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
)
require(
    "pb-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4" in THREAD_PAGE,
    "ConversationThreadPage scrollClassName must use pb-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
)

# REQ-SPACER-2: handleTranscriptScroll restores chrome at top and bottom boundaries
require(
    "const BOTTOM_MARGIN = 100;" in THREAD_PAGE,
    "ConversationThreadPage handleTranscriptScroll must define BOTTOM_MARGIN = 100"
)
require(
    "const isAtBottom = distanceToBottom <= BOTTOM_MARGIN;" in THREAD_PAGE,
    "ConversationThreadPage handleTranscriptScroll must compute isAtBottom using distanceToBottom <= BOTTOM_MARGIN"
)
require(
    "if (isAtTop || isAtBottom) {" in THREAD_PAGE or "if (isAtTop || isAtBottom) {\r\n" in THREAD_PAGE,
    "handleTranscriptScroll must restore chrome when reaching top or bottom"
)

# REQ-SPACER-3: Floating reply pill rendered when mobile chrome hidden
require(
    'data-debug-id="conversation-floating-reply-pill"' in THREAD_PAGE,
    "ConversationThreadPage must render floating reply pill with data-debug-id='conversation-floating-reply-pill'"
)
require(
    "restoreChrome();" in THREAD_PAGE and "textareaRef.current?.focus();" in THREAD_PAGE,
    "Floating reply pill onClick must restore chrome and focus textareaRef"
)
require(
    "data-debug-id=\"conversation-floating-agent-pill\"" in THREAD_PAGE,
    "Floating agent pill must still be present"
)

print("ALL STATIC REGRESSION TESTS PASSED")
