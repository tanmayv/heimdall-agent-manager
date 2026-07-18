from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = (ROOT / 'src/contracts/bridge.odin').read_text(encoding='utf-8')
BRIDGE = (ROOT / 'src/bridge/main.odin').read_text(encoding='utf-8')
PEERS = (ROOT / 'src/daemon/federation_peers.odin').read_text(encoding='utf-8')
ROUTER = (ROOT / 'src/daemon/rest_router.odin').read_text(encoding='utf-8')


def require(condition: bool, message: str):
    if not condition:
        print(f'FAIL: {message}')
        sys.exit(1)


# Shared contracts cover public daemon reachability/peer shapes and event names.
for snippet in [
    'ROUTE_FEDERATION_REACHABILITY :: "/federation/reachability"',
    'ROUTE_FEDERATION_PEERS :: "/federation/peers"',
    'Daemon_Federation_Peer :: struct',
    'Daemon_Federation_Peers_Response :: struct',
    'Daemon_Federation_Reachability_Event :: struct',
    'DAEMON_FEDERATION_REACHABILITY_EVENT :: "federation_reachability_changed"',
    'bridge_reachable: bool',
    'next_hop: Daemon_ID',
    'via: []Daemon_ID',
]:
    require(snippet in CONTRACTS, f'missing contract snippet: {snippet}')

# Bridge pushes secret-free reachability changes to the daemon and /bridge/reachable
# is still sourced from reliability-aware WS state.
require('bridge_reachability_push_to_daemon :: proc' in BRIDGE, 'bridge reachability push helper missing')
require('contracts.ROUTE_FEDERATION_REACHABILITY' in BRIDGE, 'bridge push must use shared reachability route')
require('thread.run(bridge_reachability_push_to_daemon)' in BRIDGE, 'bridge should push on WS status changes')
require('active_sessions' in BRIDGE and 'BRIDGE_WS_HEARTBEAT_TIMEOUT_MS' in BRIDGE, 'bridge status should reflect WS session/liveness state')

# Daemon owns an in-memory projection hydrated from bridge /bridge/reachable and
# updated by POST /federation/reachability.
for snippet in [
    'Reachable_Daemon_Record :: struct',
    'reachable_daemon_records',
    'reachable_daemon_hydrate_from_bridge :: proc',
    'reachable_daemon_apply_body :: proc',
    'reachable_daemon_mark_all_unreachable :: proc',
    'handle_post_federation_reachability :: proc',
    'contracts.ROUTE_BRIDGE_REACHABLE',
]:
    require(snippet in PEERS, f'missing daemon projection snippet: {snippet}')
require('handle_post_federation_reachability(client, request_body(request), ctx)' in ROUTER, 'router missing /federation/reachability handler')
require('ctx.segments[1] == "reachability"' in ROUTER, 'router should parse shared reachability path segment')

# /federation/peers response must be minimal and secret-free.
match = re.search(r'federation_peer_record_json :: proc\(builder: \^strings\.Builder, rec: Reachable_Daemon_Record\) \{(.*?)\n\}', PEERS, re.S)
require(match is not None, 'federation_peer_record_json must render reachability projection records')
peer_json = match.group(1)
for forbidden in ['peer_url', 'peer_token', 'endpoint', 'token', 'session', 'ws_socket']:
    require(forbidden not in peer_json, f'/federation/peers leaks or references {forbidden}')
for required in ['peer_id', 'daemon_id', 'kind', 'reach', 'next_hop', 'hops', 'via', 'status', 'last_seen_unix_ms', 'updated_unix_ms']:
    require(required in peer_json, f'/federation/peers missing graph-friendly field {required}')
require('"bridge_configured":`); strings.write_string(&b, "true" if bridge_client_enabled() else "false")' in PEERS, 'peers response should expose local-only bridge_configured metadata')
require('"bridge_reachable":`); strings.write_string(&b, "true" if bridge_reachable else "false")' in PEERS, 'peers response should expose secret-free bridge reachability state')
require('if !ok {\n\t\t_ = reachable_daemon_mark_all_unreachable(true)\n\t\treturn false\n\t}' in PEERS, 'hydrate failure must mark projected peers unreachable to avoid stale linked status')
require('reachable_daemon_id_seen :: proc' in PEERS, 'successful hydrate should track daemon ids present in bridge snapshot')
require('omitted from that successful snapshot' in PEERS, 'successful hydrate should document omitted-peer reconciliation')
require('if reachable_daemon_id_seen(seen_ids[:], seen_count, reachable_daemon_records[i].daemon_id) do continue' in PEERS, 'successful hydrate must reconcile omitted peers')
require('reachable_daemon_records[i].status = strings.clone(PEER_STATUS_UNREACHABLE)' in PEERS, 'omitted linked peers must be marked unreachable')
require('if bridge_client_enabled() {' in PEERS and 'bridge_reachable = reachable_daemon_hydrate_from_bridge()' in PEERS, '/federation/peers should hydrate from bridge and retain bridge_reachable result when configured')

# User WS event is compact metadata only; details are fetched via REST.
event_match = re.search(r'federation_reachability_emit_event :: proc\(.*?\) \{(.*?)\n\}', PEERS, re.S)
require(event_match is not None, 'reachability user WS event emitter missing')
event_body = event_match.group(1)
for snippet in ['changed_daemon_ids', 'changed_count', 'linked_count', 'unreachable_count', 'changed_unix_ms']:
    require(snippet in event_body, f'reachability event missing compact metadata {snippet}')
for forbidden in ['peer_url', 'peer_token', 'payload', 'body', 'endpoint', 'token']:
    require(forbidden not in event_body, f'reachability event must not include {forbidden}')

print('bridge_reachability_projection_static: ok')
