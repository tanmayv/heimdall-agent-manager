#!/usr/bin/env python3
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def read(path): return (ROOT/path).read_text()
def require(cond,msg):
    if not cond: raise AssertionError(msg)

def main():
    domain=read('src/hub/domain/agent.odin')
    svc=read('src/hub/service/agent/agent_service.odin')
    repo=read('src/hub/repository/iface/agent_repo.odin')
    sqlite=read('src/hub/repository/sqlite/agent_repo_sqlite.odin')
    wiring=read('src/hub/app/wiring.odin')
    handlers=read('src/hub/transport/http/agent_handlers.odin')
    runtime=read('src/hub/service/bridge_runtime/bridge_runtime.odin')
    bridge_handlers=read('src/hub/transport/http/bridge_handlers.odin')
    migration=read('src/hub/repository/sqlite/migrations/002_owner_scoped_core.sql')
    for s in ['Agent_Instance :: struct','agent_instance_id','provider','tier','project_path','last_applied_seq','run_count']:
        require(s in domain, f'missing AgentInstance field/contract {s}')
    for s in ['Agent_Save_Instance_Proc','agent_save_instance','agent_list_instances_by_bridge']:
        require(s in repo, f'missing instance repository API {s}')
    require('agent_instances' in migration and 'owner_user_id TEXT NOT NULL' in migration and 'last_applied_seq INTEGER NOT NULL' in migration, 'migration must persist owner-scoped instances with sequence')
    for s in ['create_instance :: proc','stop_instance :: proc','apply_bridge_status_report :: proc','reconcile_bridge_heartbeat :: proc','Bridge_Offline','launch_command_json','stop_command_json']:
        require(s in svc, f'missing HBR-15 service behavior {s}')
    require('project_service.bridge_command_send_runtime' in svc and 'bridge_runtime_registry_has_live' in svc, 'launch/stop must go through live Bridge runtime, no proxy fallback')
    require('resolve_project_path_for_launch' in svc and 'iface.project_get_bridge_path' in svc, 'launch must snapshot effective project path')
    require('runtime_status = "launching"' in svc and 'runtime_status = "stopping"' in svc, 'launch/stop statuses missing')
    require('send_runtime_command' in runtime and 'write_ws_text_frame' in runtime, 'runtime command sink must send over Bridge WS')
    require('project_service.bridge_runtime_registry_set_command_socket' in bridge_handlers, 'WS handler must register command socket')
    require('bridge_apply_heartbeat_digest' in bridge_handlers and 'agent_service.apply_bridge_status_report' in bridge_handlers and 'agent_service.reconcile_bridge_heartbeat' in bridge_handlers, 'Bridge edge reports and heartbeat instances[] digest must persist AgentInstance state')
    for route in ['"POST", "/api/v1/agent-instances"','"GET", "/api/v1/agent-instances/*"','"POST", "/api/v1/agent-instances/*/stop"']:
        require(route in wiring, f'missing route {route}')
    for s in ['create_agent_instance_handler','stop_agent_instance_handler','write_agent_instance_json']:
        require(s in handlers, f'missing handler {s}')
    require('proxy' not in svc.lower(), 'HBR-15 must not create proxy records/mappings')
    print('PASS: hub phase9 static')
if __name__=='__main__': main()
