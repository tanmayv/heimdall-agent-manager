#!/usr/bin/env python3
"""Static regression for deterministic ham-bridge peer dialing.

Symmetric [[peer]] bridge configs must not have both sides establish outgoing
websocket sessions and then tear one down. The bridge dialer should use a stable
single-dialer rule so one side dials and the other only accepts.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = (ROOT / "src/bridge/main.odin").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require('bridge_should_dial_peer :: proc(peer_name: string) -> bool' in BRIDGE, 'bridge must define deterministic dial predicate')
require('self_daemon_id := strings.trim_space(bridge_config.daemon_id)' in BRIDGE, 'dial predicate must use local daemon_id')
require('peer_daemon_id := strings.trim_space(peer_name)' in BRIDGE, 'dial predicate must use peer daemon id/name')
require('strings.compare(self_daemon_id, peer_daemon_id) < 0' in BRIDGE, 'lexicographically smaller daemon_id must be the only dialer')
require('if self_daemon_id == peer_daemon_id do return false' in BRIDGE, 'self-links must not dial themselves')
require('if strings.has_prefix(peer_daemon_id, "cli-peer-") do return true' in BRIDGE, 'CLI peer fallback should preserve legacy manual dialing')
require('if !bridge_should_dial_peer(peer_name)' in BRIDGE, 'dialer loop must consult deterministic predicate before connecting')
require('deterministic_acceptor' in BRIDGE, 'acceptor-only side should log/state why it skipped dialing')

print('bridge_deterministic_dialer_static: ok')
