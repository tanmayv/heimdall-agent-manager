#!/usr/bin/env python3
"""Static regression for conversation ordering + daemon-persisted titles (task-19f68ea0b7a)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
USER_RPC = (ROOT / "src/daemon/user_rpc.odin").read_text(encoding="utf-8")
CHAT_REST = (ROOT / "src/daemon/chat_rest.odin").read_text(encoding="utf-8")
MSG_DB = (ROOT / "src/daemon/message_db_service.odin").read_text(encoding="utf-8")
API = (ROOT / "src/ui/api/daemonApi.ts").read_text(encoding="utf-8")
SLICE = (ROOT / "src/ui/store/chatSlice.ts").read_text(encoding="utf-8")
APP = (ROOT / "src/ui/components/App.tsx").read_text(encoding="utf-8")


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f"[-] FAIL: {msg}")
        sys.exit(1)


# Backend: message-db summary query orders by last message desc and carries first user body.
require("message_db_get_chat_list_summaries" in MSG_DB, "chat list summary query missing")
require("ORDER BY last_ms DESC" in MSG_DB, "summary query must order most-recent-first")
require("Chat_List_Summary" in MSG_DB, "summary struct missing")

# Backend: list_chats + /chats emit title + last_message_unix_ms, most-recent-first.
require("chat_list_derive_title" in USER_RPC, "daemon-side title derivation missing")
require('"last_message_unix_ms":' in USER_RPC, "list_chats must emit last_message_unix_ms")
require('"title":' in USER_RPC, "list_chats must emit persisted title")
require("message_db_get_chat_list_summaries(user_id)" in USER_RPC, "list_chats must use ordered summaries")
require("message_db_get_chat_list_summaries(author)" in CHAT_REST, "/chats must use ordered summaries")
require('"last_message_unix_ms":' in CHAT_REST, "/chats must emit last_message_unix_ms")

# UI API + slice: daemon-authoritative conversation summaries.
require("export async function listConversations" in API, "listConversations API missing")
require("action: 'list_chats'" in API, "listConversations must call list_chats")
require("refreshConversationSummaries" in SLICE, "conversation summary thunk missing")
require("conversationSummaryById" in SLICE, "conversation summary state missing")
require("lastMessageUnixMs: Number(row.last_message_unix_ms" in SLICE, "summary must map last_message_unix_ms")

# UI: sidebar uses daemon summary for ordering + titles; not passive.
require("function conversationSortUnixMs(agent: any, messages: any[] = [], summary?: any)" in APP, "sort must accept daemon summary")
require("const daemonTs = Number(summary?.lastMessageUnixMs || 0);" in APP, "sort must prefer daemon last_message_unix_ms")
require("function conversationTitle(agent: any, messages: any[] = [], summary?: any)" in APP, "title must accept daemon summary")
require("const daemonTitle = String(summary?.title || '').trim();" in APP, "title must prefer daemon title")
require("dispatch(refreshConversationSummaries())" in APP, "summaries must refresh on explicit triggers")
require("summaryById={conversationSummaryById}" in APP, "sidebar must receive daemon summaries")

print("PASS: conversation ordering + daemon title static checks")
