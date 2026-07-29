#!/usr/bin/env python3
"""Static regression for the mobile-first Conversations inbox/home.

Covers the API and UI contract requested for the chat-like Conversations tab:
- /conversations renders a real inbox, not a placeholder;
- rows use summary data only and navigate to the existing conversation view;
- summaries expose a backward-compatible /api/v1/chats shape plus additive
  standard last_message/participants fields.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = (ROOT / "src/ui/components/shell/AppShell.tsx").read_text(encoding="utf-8")
HOME = (ROOT / "src/ui/components/chat/ConversationsHomePage.tsx").read_text(encoding="utf-8")
SIDEBAR_API = (ROOT / "src/ui/api/endpoints/sidebar.ts").read_text(encoding="utf-8")
CONTENT = (ROOT / "src/hub/transport/http/content_handlers.odin").read_text(encoding="utf-8")
SQLITE = (ROOT / "src/hub/repository/sqlite/content_repo_sqlite.odin").read_text(encoding="utf-8")
DOMAIN = (ROOT / "src/hub/domain/content.odin").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# Route/home wiring: /conversations is a real page, /conversations/:id remains the
# existing thread route, so clicking a row opens the conversation view.
require("import ConversationsHomePage" in SHELL, "AppShell must import ConversationsHomePage")
require("path === '/conversations'" in SHELL and "<ConversationsHomePage />" in SHELL,
        "/conversations must render the inbox page")
require("isConversationThreadRoute" in SHELL and "<ConversationThreadPage" in SHELL,
        "conversation detail route must still open the existing thread view")
require("href={buildRouteHash(`/conversations/${encodeURIComponent(conversation.conversationId)}`, '')}" in HOME,
        "conversation inbox rows must link to the existing conversation route")

# Mobile-first UI and row content: touch-friendly list rows with clear title,
# last message prefix, timestamp, unread badge, and pagination.
for marker in [
    'data-debug-id="conversations-home-page"',
    'data-debug-id="conversation-inbox-list"',
    'min-h-[76px]',
    'conversation-inbox-title-',
    'conversation-inbox-last-message-',
    'conversation-inbox-last-message-label-',
    'conversation-inbox-timestamp-',
    'conversation-inbox-unread-',
    'conversation-inbox-load-more-btn',
]:
    require(marker in HOME, f"ConversationsHomePage missing mobile/inbox marker: {marker}")
require("const sent = direction === 'sent' || rawDirection === 'user_to_agent'" in HOME,
        "last-message label must distinguish sent messages")
require("const prefix = sent ? 'You'" in HOME and "'Received'" in HOME,
        "last-message label must show You:/Received-style clarity")

# Data efficiency: the inbox uses summary rows and must not fetch every thread's
# full message history to render the list.
require("useListConversationInboxQuery" in HOME and "useLazyListConversationInboxQuery" in HOME,
        "inbox must use the paged summary endpoint")
for forbidden in ["fetchConversationMessages", "useFetchConversationMessages", "/messages?"]:
    require(forbidden not in HOME, f"inbox must not fetch full histories per row: {forbidden}")

# UI API: standard additive chat-list params/fields while preserving existing
# sidebar fields/aliases.
for marker in [
    "listConversationInbox",
    "include: 'last_message,participants'",
    "sort: '-last_message_at'",
    "lastMessagePreview",
    "lastMessageDirection",
    "lastMessageUnixMs",
    "participants",
    "lastMessage",
    "useListSidebarConversationsQuery",
]:
    require(marker in SIDEBAR_API, f"sidebar/inbox endpoint missing: {marker}")

# Hub response: existing /chats rows keep backward-compatible aliases while adding
# conventional last_message and participants fields plus stable page cursors.
for marker in [
    "list_chats_handler",
    "include:=query_value(req.query,\"include\")",
    "sort:=query_value(req.query,\"sort\")",
    "chat_page_cursor",
    "last_message_preview",
    "last_message_at",
    "last_message_unix_ms",
    "participants",
    "last_message",
    "direction",
    "body_preview",
    "chat_last_message_standard_direction",
    "query_component_decode",
]:
    require(marker in CONTENT, f"Hub chat list response missing: {marker}")
require("last_message_id" in DOMAIN and "last_message_direction" in DOMAIN,
        "domain summary fields must carry last-message metadata without extra UI fetches")
require("ORDER BY " in SQLITE and "conversation_id DESC" in SQLITE and "chat_messages m" in SQLITE,
        "SQLite conversation list must be backend-authoritative, newest-first with stable tie-breaker")
require("direction != 'agent_to_agent'" in SQLITE,
        "last-message summary should use user-visible messages, not hidden agent-to-agent rows")

print("PASS: mobile Conversations inbox route, API summary shape, navigation, and UI contract")
