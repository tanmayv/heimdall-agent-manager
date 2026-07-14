#!/usr/bin/env python3
"""Regression: stale pre-token wrappers must not recreate dropped DB records."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LIFECYCLE = (ROOT / 'src/daemon/lifecycle.odin').read_text(encoding='utf-8')
WRAPPER = (ROOT / 'src/wrapper/main.odin').read_text(encoding='utf-8')
REGISTRY = (ROOT / 'src/daemon/registry.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str) -> None:
    if not condition:
        print(f'FAILED: {message}')
        sys.exit(1)


register_block = LIFECYCLE.split('handle_register :: proc', 1)[1].split('handle_startup_report :: proc', 1)[0]
require('durable_agent_exists := agent_record_index_by_instance(agent_instance_id) >= 0' in register_block, 'register should compute durable record existence before accepting pre-issued tokens')
require('registry_consume_pending_agent_token(agent_instance_id, requested_agent_token)' in register_block, 'pending daemon launch tokens should remain trusted')
require('auth_db_get_identity(requested_agent_token)' in register_block, 'daemon restart recovery should validate persisted auth token')
require('if itype == "agent" && iid == agent_instance_id' in register_block, 'persisted auth token must map to the same agent')
require('!trusted_preissued_token' in register_block and '"stale_agent_token"' in register_block, 'stale pre-issued token should be rejected explicitly')
require(register_block.index('!trusted_preissued_token') < register_block.index('if !durable_agent_exists'), 'stale pre-issued token must be rejected before durable record upsert')

pending_block = REGISTRY.split('registry_add_pending_agent_token :: proc', 1)[1].split('registry_consume_pending_agent_token :: proc', 1)[0]
require('auth_db_store_token(agent_token, "agent", agent_instance_id, now)' in pending_block, 'daemon-issued pending launch token should be persisted before wrapper first register')

close_block = WRAPPER.split('close_wrapper_after_auth_failure :: proc', 1)[1].split('reregister_and_reconnect_ws :: proc', 1)[0]
require('tmux.kill_pane(tmux_pane)' in close_block, 'wrapper auth failure should kill the agent pane')
require('tmux.kill_window(tmux_session, window_name)' in close_block, 'wrapper auth failure should kill the tmux window')
require('register_response.status == 401 || register_response.status == 409' in WRAPPER, 'wrapper re-registration should treat 401/409 as terminal')
require('heartbeat_409' in WRAPPER, 'heartbeat conflict should use fatal close path')
require('closing wrapper and agent process' in WRAPPER, 'wrapper logs should make process kill explicit')

print('STALE WRAPPER REGISTER CONTRACT TEST PASSED')
