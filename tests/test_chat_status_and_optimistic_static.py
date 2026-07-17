#!/usr/bin/env python3
"""Static regression checks for chat optimistic dedupe and status propagation."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHAT_SLICE = (ROOT / "src/ui/store/chatSlice.ts").read_text(encoding="utf-8")
CHAIN_VIEW = (ROOT / "src/ui/store/chainViewSlice.ts").read_text(encoding="utf-8")
WS = (ROOT / "src/ui/api/wsInvalidation.ts").read_text(encoding="utf-8")
CHAT_EVENTS = (ROOT / "src/daemon/chat_events.odin").read_text(encoding="utf-8")
CHAT_HTTP = (ROOT / "src/daemon/chat_http.odin").read_text(encoding="utf-8")
USER_RPC = (ROOT / "src/daemon/user_rpc.odin").read_text(encoding="utf-8")
AGENT_RPC = (ROOT / "src/daemon/agent_rpc.odin").read_text(encoding="utf-8")
SCHEDULED = (ROOT / "src/daemon/scheduled_prompt_service.odin").read_text(encoding="utf-8")
MESSAGE_DB = (ROOT / "src/daemon/message_db_service.odin").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"FAIL: {message}")


# Optimistic metadata must survive appendMessage(mapMessage()), otherwise local_ coordinator
# sends are not matched to the authoritative WS/HTTP message and appear twice until refresh.
require("sending: Boolean(message.sending)" in CHAT_SLICE, "mapMessage must preserve sending")
require("optimistic: Boolean(message.optimistic)" in CHAT_SLICE, "mapMessage must preserve optimistic")
require("String(message.id || '').startsWith('local_')" in CHAT_SLICE, "optimistic merge must recognize local_ ids")
require("dispatch(appendMessage({" in CHAIN_VIEW and "id: result.message_id" in CHAIN_VIEW, "coordinator sends must reconcile local optimistic row with server id")

# Status-only websocket events must patch existing messages rather than only invalidating summaries.
require("patchChatMessageStatus" in CHAT_SLICE, "chat slice must expose status patch reducer")
require("dispatch(patchChatMessageStatus(statusPatch))" in WS, "WS status events must patch legacy chat cache")
require("statusPatch.deliveredUnixMs" in WS and "statusPatch.readUnixMs" in WS, "WS status patch must include delivered/read timestamps")

# Delivery/read status transitions should go through shared helpers so future send paths don't
# forget timestamps or fanout payload fields.
require("chat_mark_delivered_and_fanout :: proc" in CHAT_EVENTS, "shared delivered helper missing")
require("chat_mark_read_and_fanout :: proc" in CHAT_EVENTS, "shared read helper missing")
for name, text in {
    "chat_http": CHAT_HTTP,
    "user_rpc": USER_RPC,
    "scheduled_prompt_service": SCHEDULED,
}.items():
    require("chat_mark_delivered_and_fanout" in text, f"{name} should use delivered helper")
require("chat_mark_read_and_fanout" in CHAT_HTTP, "chat inbox should mark fetched user messages read")
require("chat_mark_read_and_fanout" in AGENT_RPC, "agent fetch_user_chat should fanout read status")

for name, text in {
    "chat_http": CHAT_HTTP,
    "user_rpc": USER_RPC,
    "agent_rpc": AGENT_RPC,
    "scheduled_prompt_service": SCHEDULED,
}.items():
    require("chat_event_fanout" not in text or '"delivered"' not in text, f"{name} should not hand-roll delivered fanout")

# Fetched messages should carry read_unix_ms from conversation read watermarks so refresh and
# fetchChatMessage agree with live status events.
require("message_db_read_unix_for_message :: proc" in MESSAGE_DB, "message DB read timestamp helper missing")
require(MESSAGE_DB.count("message_db_read_unix_for_message(msg.direction") >= 3, "all fetch/get message paths should hydrate read_unix_ms")

print("chat_status_and_optimistic_static: ok")
