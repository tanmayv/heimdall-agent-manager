#!/usr/bin/env python3
"""Static checks for HBR-13/HBR-14 Bridge runtime protocol."""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def require(ok, msg):
    if not ok: raise AssertionError(msg)

def read(rel): return (ROOT/rel).read_text(encoding='utf-8')

def test_runtime_protocol_markers():
    runtime = read('src/hub/service/bridge_runtime/runtime_protocol.odin')
    handlers = read('src/hub/transport/http/bridge_handlers.odin')
    sink = read('src/hub/service/bridge_runtime/bridge_runtime.odin')
    for s in ['PROTOCOL_VERSION :: 1', 'runtime_accept_hello', 'unsupported bridge protocol_version', 'replaced_existing', 'connection_generation', 'bridge_runtime_registry_generation', 'connection_replaced']:
        require(s in runtime or s in handlers, f'missing hello marker {s}')
    for s in ['runtime_command_result_idempotent', 'command_ids', 'command_results_json']:
        require(s in runtime or s in read('src/hub/service/project/project_service.odin'), f'missing command idempotency marker {s}')
    for s in ['runtime_apply_state_report', 'state_seq <=', 'runtime_reconcile_digest', 'unreachable', 'edge_event_count']:
        require(s in runtime, f'missing coalesced reporting marker {s}')
    for s in ['bridge_heartbeat_ack', 'agent_instance_status_ack']:
        require(s in handlers, f'missing real WS ack marker {s}')
    for s in ['ws.connect', 'ws.send_text', 'ws.poll_text', 'project_path_validation_result']:
        require(s in sink, f'missing websocket command marker {s}')
    require('body_bridge_id != "" && body_bridge_id != bridge.bridge_id' in handlers, 'bridge_id/token mismatch must be rejected')
    wiring = read('src/hub/app/wiring.odin')
    require('router_add_upgrade(&graph.router, "GET", "/api/v1/bridge-ws"' in wiring, 'bridge-ws must be WebSocket upgrade route')
    require('router_add(&graph.router, "POST", "/api/v1/bridge-ws"' not in wiring and 'router_add(&graph.router, "GET", "/api/v1/bridge-ws"' not in wiring, 'bridge-ws must not expose non-upgrade HTTP fallback')

if __name__ == '__main__':
    test_runtime_protocol_markers()
    print('PASS: hub phase8 static')
