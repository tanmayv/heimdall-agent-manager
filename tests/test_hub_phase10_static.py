#!/usr/bin/env python3
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def read(path): return (ROOT/path).read_text()
def require(cond,msg):
    if not cond: raise AssertionError(msg)

def main():
    wiring=read('src/hub/app/wiring.odin')
    user=read('src/hub/transport/http/user_handlers.odin')
    bridge=read('src/hub/transport/http/bridge_handlers.odin')
    events=read('src/hub/service/events/event_bus.odin')
    agent=read('src/hub/service/agent/agent_service.odin')
    bridge_boot=read('src/bridge/bootstrap_service.odin')
    require('router_add_upgrade(&graph.router, "GET", "/api/v1/user-ws"' in wiring, 'user-ws must be WS upgrade route')
    require('router_add(&graph.router, "GET", "/api/v1/bridge/agent-instances/*/bootstrap"' in wiring, 'bootstrap fetch route missing')
    for s in ['user_ws_upgrade_handler','resolve_auth','Sec-WebSocket-Key','user_ws_ready']:
        require(s in user, f'user WS missing {s}')
    for s in ['User_Event_Bus','publish_resource_changed','resource_changed','resource_id','summary']:
        require(s in events, f'event bus missing {s}')
    require('events.publish_resource_changed' in bridge and 'agent_instance_status_summary_json' in bridge, 'Bridge status reports must publish user invalidations')
    require('events.publish_resource_changed' in read('src/hub/transport/http/agent_handlers.odin'), 'AgentInstance create/stop must publish invalidations')
    require('bridge_instance_bootstrap_handler' in bridge and 'verify_bridge_token' in bridge and 'reject_query_or_body_token' in bridge, 'bootstrap fetch must be Bridge bearer-only')
    # Bootstrap caching refactor: the legacy bundle (bootstrap_json_for_bridge) is
    # replaced by the conditional, agent-keyed manifest + per-hash blobs. The
    # manifest still carries the instance token + managed files (assembly/skills).
    require('bootstrap_manifest_json_for_bridge' in agent and 'instance_token' in agent and 'files' in agent, 'bootstrap manifest must include token and managed files')
    require('bridge_agent_manifest_handler' in bridge and 'bridge_blob_handler' in bridge, 'hub must expose conditional manifest + per-hash blob handlers')
    for s in ['bridge_bootstrap_launch_materialize','Authorization','Bearer','AGENTS.md','heimdall-bootstrap-manifest.json','os.write_entire_file']:
        require(s in bridge_boot, f'Bridge bootstrap materialization missing {s}')
    print('PASS: hub phase10 static')
if __name__=='__main__': main()
