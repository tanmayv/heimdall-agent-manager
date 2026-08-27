#!/usr/bin/env python3
"""Regression: start-success must not fire a false 'New message from user'
notification.

Previously agent_action_start_success_handler scanned the last 50 messages and
called notify_agent_message for the first user_to_agent row it found, regardless
of whether that message was already read. That produced a spurious
"New message from user" notification on every start-success (even when the inbox
was empty/already read), followed by `chat read` returning messages: [].

The fix only re-notifies for genuinely unread inbound messages, using the same
inbox semantics as the agent inbox read path (unread_only + receiver_only).
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
HANDLERS = (ROOT / 'src/hub/transport/http/agent_action_handlers.odin').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


# Isolate the start-success handler body.
m = re.search(
    r'agent_action_start_success_handler ::.*?\n\}',
    HANDLERS,
    re.S,
)
require(m is not None, 'start-success handler not found')
body = m.group(0)

# Must NOT use the naive list_messages scan that ignored read state.
require(
    'content_service.list_messages(' not in body,
    'start-success must not scan all recent messages via list_messages',
)

# Must use the unread-only inbox filter, matching chat read semantics.
require(
    'content_service.list_agent_inbox_messages(' in body,
    'start-success should query the agent inbox (list_agent_inbox_messages)',
)
require(
    'unread_only' in body and 'true' in body,
    'start-success inbox query must set unread_only = true',
)
require(
    'receiver_only' in body,
    'start-success inbox query must set receiver_only',
)

# Only notify when the message is actually unread and inbound.
require(
    'msg.read_at == ""' in body,
    'start-success must guard notify on an unread (read_at == "") message',
)
require(
    'msg.direction == "user_to_agent"' in body,
    'start-success must only notify for inbound user_to_agent messages',
)

# notify_agent_message must be gated behind those checks (appears after them).
notify_idx = body.find('notify_agent_message')
guard_idx = body.find('msg.read_at == ""')
require(notify_idx != -1, 'start-success must still be able to notify for real unread messages')
require(guard_idx != -1 and guard_idx < notify_idx,
        'notify_agent_message must be gated by the unread guard')

print('START SUCCESS NO FALSE NOTIFY TEST PASSED')
