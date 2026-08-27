#!/usr/bin/env python3
"""Regression: the canonical permission-relay contract is wired end-to-end.

Task 1 (wrapper core + bridge contract) defines the second half of the normalized
bridge contract used by per-provider adapters:

  upstream   (adapter -> bridge): agent.permission.request {request_id,tool,input,risk}
  downstream (bridge  -> adapter): permission_reply {request_id,decision,reason}

This static check asserts the transport plumbing exists across bridge + wrapper so
the Pi/Antigravity adapter tasks can build on a stable base.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = (ROOT / 'src/bridge/wrapper_endpoint.odin').read_text(encoding='utf-8')
RELAY = (ROOT / 'src/bridge/permission_relay.odin').read_text(encoding='utf-8')
WRAPPER = (ROOT / 'src/wrapper/bridge_runtime.odin').read_text(encoding='utf-8')


def require(cond: bool, msg: str) -> None:
    if not cond:
        print(f'FAILED: {msg}')
        sys.exit(1)


# --- Bridge allowlist exposes the two new agent methods ---
allow = re.search(r'case \.Agent:\s*\n\s*return (.*?)\n', ENDPOINT, re.S)
require(allow is not None, 'agent method allowlist not found')
allow_body = allow.group(1)
require('"agent.permission.request"' in allow_body, 'agent.permission.request must be allowlisted for Agent role')
require('"agent.permission.reply"' in allow_body, 'agent.permission.reply must be allowlisted for Agent role')

# --- Bridge handler dispatches both methods ---
require('if method == "agent.permission.request"' in ENDPOINT, 'bridge must handle agent.permission.request')
require('if method == "agent.permission.reply"' in ENDPOINT, 'bridge must handle agent.permission.reply')
require('bridge_permission_handle_request(' in ENDPOINT, 'request handler must call bridge_permission_handle_request')
require('bridge_permission_resolve(' in ENDPOINT, 'reply handler must call bridge_permission_resolve')

# --- Relay module implements the contract primitives ---
for sym in [
    'bridge_permission_register',
    'bridge_permission_resolve',
    'bridge_permission_wait',
    'bridge_permission_normalize_decision',
    'bridge_permission_request_push_json',
    'bridge_permission_reply_push_json',
    'bridge_permission_handle_request',
]:
    require(f'{sym} ::' in RELAY, f'permission_relay must define {sym}')

# Fail-safe deny on timeout.
require('return "deny", "permission request timed out"' in RELAY, 'wait must fail-safe to deny on timeout')
# Mirror request to wrapper/UI push channel.
require('bridge_wrapper_push_line(' in RELAY, 'request handler must mirror to the wrapper push channel')
# Downstream push shapes (Odin source escapes the quotes).
require('push\\":\\"permission_request' in RELAY, 'must emit permission_request push')
require('push\\":\\"permission_reply' in RELAY, 'must emit permission_reply push')

# --- Wrapper mirrors both pushes and the Pi extension has a blocking gate ---
require('push\\":\\"permission_request' in WRAPPER, 'wrapper must dispatch permission_request pushes')
require('push\\":\\"permission_reply' in WRAPPER, 'wrapper must dispatch permission_reply pushes')
require('wrapper_bridge_deliver_permission_request_push' in WRAPPER, 'wrapper must handle permission_request push')
require('wrapper_bridge_deliver_permission_reply_push' in WRAPPER, 'wrapper must handle permission_reply push')

# Pi extension: blocking request/response + opt-in gate + block/allow mapping.
require('agent.permission.request' in WRAPPER, 'Pi extension must call agent.permission.request')
require('function bridgeRequest(' in WRAPPER, 'Pi extension must have a blocking bridgeRequest helper')
require('HEIMDALL_PERMISSION_GATE' in WRAPPER, 'gate must be opt-in via HEIMDALL_PERMISSION_GATE')
require('block: true' in WRAPPER, 'deny must map to Pi { block: true }')
require('function toolRisk(' in WRAPPER, 'Pi extension must classify tool risk (safe vs risky)')

print('PERMISSION RELAY CONTRACT STATIC TEST PASSED')
