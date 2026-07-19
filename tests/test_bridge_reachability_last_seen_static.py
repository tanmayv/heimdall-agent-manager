#!/usr/bin/env python3
"""Static regression for bridge reachability last_seen refreshes.

Successful /bridge/reachable polls must advance last_seen_unix_ms for linked
peers even when the websocket session remains continuously linked, so daemon
poll-driven replay paths can observe fresh timestamps.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "src/bridge/main.odin").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require('bridge_peer_state_refresh_last_seen_for_linked_locked :: proc()' in BRIDGE, 'bridge must define a linked-peer last_seen refresh helper')
require('if bridge_peer_states[i].status != .Linked do continue' in BRIDGE, 'refresh helper must only touch linked peers')
require('if bridge_peer_states[i].last_seen_unix_ms >= now do now = bridge_peer_states[i].last_seen_unix_ms + 1' in BRIDGE, 'refresh helper must keep last_seen monotonic across polls')
require('bridge_peer_state_refresh_last_seen_for_linked_locked()' in BRIDGE, 'reachable JSON path must refresh linked last_seen before responding')
require('strings.write_string(&b, `","via":[],"last_seen_unix_ms":`); strings.write_string(&b, fmt.tprintf("%d", state.last_seen_unix_ms))' in BRIDGE, 'reachable payload must serialize the refreshed last_seen_unix_ms value')

print('bridge_reachability_last_seen_static: ok')
