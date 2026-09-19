#!/usr/bin/env python3
"""Static layout regression test for ConversationThreadPage 2-column refactor.

Requirements covered:
- REQ-UI-LAYOUT-2COL:
  * Root <section data-debug-id="conversation-thread-page"> uses 2-column flex layout
    (flex flex-col sm:flex-row h-full min-h-0 w-full).
  * Root <header data-debug-id="conversation-thread-header"> is removed as a direct child
    of the root <section> and moved inside Col 1 (conversation-chat-column) above transcript.
  * Col 1 container expands with flex-1 and enforces sm:min-w-[380px].
- REQ-UI-TOPBAR-BREADCRUMB:
  * In Col 1 top bar, renders left-aligned breadcrumb title <project> / <chain title || title>.
  * Font styling uses text-sm font-medium matching icon height (~16px).
  * Dummy centering spacer (hidden h-9 w-9 shrink-0 sm:block) is removed.
- REQ-UI-TOPBAR-ACTIONS:
  * Inline pencil edit button removed from next to title.
  * Three-dots menu button (<Icon name="more-horizontal" size={16} />) in top bar.
  * Menu contains "Rename conversation" action triggering rename flow (beginRenameFromHeader).
  * Menu contains "Refresh messages" action and conversation/agent details.
  * Search button (conversation-search-btn) retained in top bar.
- REQ-UI-SIDEBAR-TOGGLE:
  * In Col 1 top bar: sidebar open toggle (conversation-right-panel-toggle-btn) with
    <Icon name="panel-right" size={18} /> and progress pill rendered only when right panel is CLOSED.
  * In Col 2 header (conversation-right-panel-tabs): right-aligned close toggle button
    (conversation-right-panel-close-btn) with <Icon name="panel-right" size={16} /> to close sidebar when OPEN.
- REQ-UI-MOBILE-RESPONSIVE:
  * Mobile view (< 768px) overlays sidebar with close button.
  * Mobile scroll-hide and floating reply pill preserved when closed.
- REQ-MOBILE-TOPBAR-FIX:
  * <header> uses fixed on mobile and relative on desktop without class collision.
  * Chat transcript has pt-16 top padding clearance.
- REQ-VAL-MOBILE-FIX:
  * Validates clean header class separation and mobile overlay semantics.
- REQ-VAL-UI-2COL-1:
  * Validates all requirements via static pattern analysis.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONVERSATION_FILE = ROOT / "src" / "ui" / "components" / "chat" / "ConversationThreadPage.tsx"
ICON_FILE = ROOT / "src" / "ui" / "components" / "ui" / "primitives" / "Icon.tsx"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_2column_layout_structure() -> None:
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # Outer container is a 2-column flex layout
    require('data-debug-id="conversation-thread-page"' in src,
            "Root section must have data-debug-id='conversation-thread-page'")
    require("flex flex-col sm:flex-row h-full min-h-0 w-full" in src,
            "Outer container must be a 2-column flex layout (flex flex-col sm:flex-row h-full min-h-0 w-full)")

    # Col 1 chat column container
    require('data-debug-id="conversation-chat-column"' in src,
            "Col 1 must have data-debug-id='conversation-chat-column'")
    require("flex-1 flex-col sm:min-w-[380px]" in src,
            "Col 1 chat column must have flex-1 flex-col sm:min-w-[380px]")

    # Header is inside Col 1 above transcript
    chat_col_idx = src.find('data-debug-id="conversation-chat-column"')
    header_idx = src.find('data-debug-id="conversation-thread-header"')
    resizer_idx = src.find('data-debug-id="conversation-right-panel-resizer"')
    sidebar_idx = src.find('data-debug-id="conversation-right-panel-resizable-container"')

    require(chat_col_idx != -1, "Col 1 chat column missing")
    require(header_idx != -1, "Header missing")
    require(chat_col_idx < header_idx, "Header must be located inside Col 1 chat column")
    require(header_idx < resizer_idx if resizer_idx != -1 else True,
            "Header must precede resizer")
    require(resizer_idx < sidebar_idx if resizer_idx != -1 else True,
            "Resizer must precede Col 2 sidebar container")


def test_topbar_breadcrumb() -> None:
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # Breadcrumb container matching text-sm font size
    require('data-debug-id="conversation-thread-breadcrumb"' in src,
            "Col 1 top bar must render breadcrumb with data-debug-id='conversation-thread-breadcrumb'")
    require("font-medium" in src,
            "Breadcrumb must use font-medium styling")
    require("text-sm" in src,
            "Breadcrumb must match text-sm font size (one level down)")

    # Breadcrumb components: project, slash separator, and chain/conversation title
    require('data-debug-id="conversation-breadcrumb-project"' in src,
            "Breadcrumb must render project with data-debug-id='conversation-breadcrumb-project'")
    require('data-debug-id="conversation-thread-title"' in src,
            "Breadcrumb must render title with data-debug-id='conversation-thread-title'")
    require("chainTitle || title" in src,
            "Breadcrumb title must resolve <chain title || title>")
    require('projectName || \'Project\'' in src or 'projectName' in src,
            "Breadcrumb project must resolve <project>")

    # Left-aligned: no dummy spacer pushing title to center
    require("hidden h-9 w-9 shrink-0 sm:block" not in src,
            "Centering dummy spacer must be removed for left-aligned breadcrumb")


def test_topbar_actions() -> None:
    src = CONVERSATION_FILE.read_text(encoding="utf-8")
    icon_src = ICON_FILE.read_text(encoding="utf-8")

    # Icon primitive supports more-horizontal
    require("'more-horizontal'" in icon_src,
            "Icon primitive must support more-horizontal glyph")

    # Inline pencil edit button next to title is removed
    require('data-debug-id="conversation-thread-title-edit-btn"' not in src,
            "Inline pencil edit button next to title must be removed")

    # Three-dots menu button in top bar
    require('data-debug-id="conversation-thread-overflow-menu-btn"' in src,
            "Top bar must render three-dots menu button with data-debug-id='conversation-thread-overflow-menu-btn'")
    require('Icon name="more-horizontal"' in src or 'Icon name="more"' in src,
            "Three-dots menu button must render more-horizontal or more icon")

    # Menu item: Rename conversation triggering rename input flow
    require('data-debug-id="conversation-thread-rename-action"' in src,
            "Menu must contain 'Rename conversation' action with data-debug-id='conversation-thread-rename-action'")
    require("Rename conversation" in src,
            "Menu must display 'Rename conversation' text")
    require("beginRenameFromHeader" in src,
            "Rename action must invoke beginRenameFromHeader")

    # Menu items: Refresh messages and conversation/agent details
    require('data-debug-id="conversation-thread-refresh-btn"' in src,
            "Menu must contain 'Refresh messages' button")
    require('data-debug-id="conversation-thread-overflow-details"' in src,
            "Menu must contain conversation/agent details")

    # Top bar retains search button
    require('data-debug-id="conversation-search-btn"' in src,
            "Top bar must retain search button with data-debug-id='conversation-search-btn'")

    # Top bar has no bottom border and includes blur-fade overlay
    require('data-debug-id="conversation-topbar-blur-fade"' in src,
            "Top bar must render bottom blur-fade overlay with data-debug-id='conversation-topbar-blur-fade'")
    require("backdrop-blur-sm" in src or "backdrop-blur" in src,
            "Top bar blur-fade overlay must use backdrop-blur")
    require("w-64" in src,
            "Three-dots menu must have dedicated width w-64")
    require("overflow-visible" in src,
            "Header must retain overflow-visible")
    require("relative z-20" in src,
            "Header must have relative z-20 stacking context on desktop")

    # Header positioning: conditional fixed on mobile and relative on desktop without class collision (REQ-MOBILE-TOPBAR-FIX)
    header_start = src.find('data-debug-id="conversation-thread-header"')
    require(header_start != -1, "Header element must exist")
    header_chunk = src[header_start:header_start + 450]
    require("isMobile" in header_chunk, "Header classes must branch on isMobile")
    base_classes = header_chunk.split("isMobile")[0]
    require("relative" not in base_classes,
            "Header base classes must not contain unconditional relative (avoids mobile fixed collision)")
    require("fixed top-0 inset-x-0" in header_chunk,
            "Header must apply fixed top-0 inset-x-0 overlay positioning on mobile")


def test_sidebar_toggle_buttons() -> None:
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # Col 1 top bar: sidebar toggle when right panel is CLOSED
    require("rightPanel === 'closed'" in src,
            "Col 1 top bar sidebar toggle must check rightPanel === 'closed'")
    require('data-debug-id="conversation-right-panel-toggle-btn"' in src,
            "Col 1 top bar must render data-debug-id='conversation-right-panel-toggle-btn' when closed")
    require('data-debug-id="conversation-right-panel-toggle-progress"' in src,
            "Col 1 top bar sidebar toggle must display chain progress badge when closed")

    # Col 2 tabs header: right-aligned close toggle button when OPEN
    require('data-debug-id="conversation-right-panel-close-btn"' in src,
            "Col 2 header must contain data-debug-id='conversation-right-panel-close-btn'")
    require('Icon name="panel-right" size={16}' in src,
            "Col 2 close toggle button must render panel-right icon with size 16")
    require("closeRightPanel" in src,
            "Col 2 close toggle button must trigger closeRightPanel")
    require("ml-auto" in src,
            "Col 2 close toggle button must be right-aligned with ml-auto")


def test_mobile_responsive() -> None:
    src = CONVERSATION_FILE.read_text(encoding="utf-8")

    # Mobile overlay renders right panel when panelOpen
    require("sm:hidden" in src and "renderRightPanel(true)" in src,
            "Mobile view (< 768px) must render right panel in full-screen overlay")

    # Mobile scroll-hide transitions preserved
    require("-translate-y-full opacity-0 pointer-events-none" in src,
            "Header mobile scroll-hide transition must be preserved")
    require('data-debug-id="conversation-floating-reply-pill"' in src,
            "Floating reply pill on mobile must be preserved when chrome is hidden")

    # Mobile overlay semantics and transcript padding clearance (REQ-MOBILE-TOPBAR-FIX, REQ-VAL-MOBILE-FIX)
    require("fixed top-0 inset-x-0 z-20 h-14" in src,
            "Header must use fixed top-0 overlay semantics on mobile")
    require("fixed bottom-14 inset-x-0 z-20" in src,
            "Composer must use fixed bottom-14 overlay semantics on mobile")
    require("pt-16 pb-4" in src,
            "Transcript scroll container must have pt-16 top padding clearance for fixed header")


def test_chat_and_composer_max_width() -> None:
    conv_src = CONVERSATION_FILE.read_text(encoding="utf-8")
    chat_list_file = ROOT / "src" / "ui" / "components" / "chat" / "ChatMessageList.tsx"
    chat_list_src = chat_list_file.read_text(encoding="utf-8")

    # Chat transcript messages centered with max-w-4xl
    require('data-debug-id={`${debugPrefix}-messages-container`}' in chat_list_src,
            "ChatMessageList must wrap messages in messages-container")
    require("mx-auto w-full max-w-4xl" in chat_list_src,
            "ChatMessageList must center messages with mx-auto w-full max-w-4xl")

    # Composer centered with max-w-4xl
    require("mx-auto w-full max-w-4xl" in conv_src,
            "ConversationThreadPage composer must center card with mx-auto w-full max-w-4xl")


def main() -> None:
    test_2column_layout_structure()
    test_topbar_breadcrumb()
    test_topbar_actions()
    test_sidebar_toggle_buttons()
    test_mobile_responsive()
    test_chat_and_composer_max_width()
    print("PASS: test_ui_conversation_2col_layout_static (REQ-UI-LAYOUT-2COL, REQ-UI-TOPBAR-BREADCRUMB, REQ-UI-TOPBAR-ACTIONS, REQ-UI-SIDEBAR-TOGGLE, REQ-UI-MOBILE-RESPONSIVE, REQ-UI-CHAT-MAXWIDTH, REQ-VAL-UI-2COL-1)")


if __name__ == "__main__":
    main()
