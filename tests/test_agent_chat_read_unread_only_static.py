#!/usr/bin/env python3
"""Static contract checks for low-noise agent chat read filters and metadata."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)

def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")

def main():
    agent_mode = read("src/ctl/agent_mode.odin")
    action_handlers = read("src/hub/transport/http/agent_action_handlers.odin")
    content_repo = read("src/hub/repository/sqlite/content_repo_sqlite.odin")

    require('unread_only := true' in agent_mode, "agent_mode must default to unread_only=true")
    require('receiver_only := true' in agent_mode, "agent_mode must default to receiver_only=true")
    require('include_outgoing := false' in agent_mode, "agent_mode must default to include_outgoing=false")
    require('include_debug := false' in agent_mode, "agent_mode must default to include_debug=false")
    require('has_flag(args, "--include-read")' in agent_mode, "agent_mode must support --include-read flag")

    require('\\"mode\\":' in action_handlers, "API response must include explicit mode")
    require('\\"filters\\":' in action_handlers, "API response must include filters block")
    require('\\"unread_count_before\\":' in action_handlers, "API response must include unread_count_before")
    require('\\"read\\":{' in action_handlers, "API response must include read metadata block")

    require('unread_only' in content_repo, "SQLite repo must filter by unread_only")
    require('receiver_only' in content_repo, "SQLite repo must filter by receiver_only")
    require("direction != 'agent_to_agent' OR sender_agent_instance_id != ?" in content_repo, "SQLite receiver_only filter must correctly allow inbound messages without relying on IS NULL")

    require('process_agent_chat_fetch_or_read' in action_handlers, "API handlers must use a shared fetch-and-read procedure")
    require('process_agent_chat_fetch_or_read(ctx, req, true)' in action_handlers, "API chat read handler must set mark_read to true")

    print('PASS: agent chat read unread-only static')

if __name__ == '__main__':
    main()
