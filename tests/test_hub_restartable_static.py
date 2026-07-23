#!/usr/bin/env python3
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text()
def require(c,m):
    if not c: raise AssertionError(m)
def main():
    svc=read('src/hub/service/agent/agent_service.odin')
    handlers=read('src/hub/transport/http/agent_handlers.odin')
    content_handlers=read('src/hub/transport/http/content_handlers.odin')
    wiring=read('src/hub/app/wiring.odin')
    domain=read('src/hub/domain/agent.odin')
    for s in ['run_count','started_at','stopped_at','last_applied_seq','chain_id','conversation_id']:
        require(s in domain, f'missing restartable field {s}')
    for s in ['restart_instance :: proc','reconfigure_instance :: proc','relaunch_instance :: proc','ensure_instance_conversation','resolve_instance_chain','taskchain_get_chain','content_save_conversation','validate_pinned_provider_tier','validate_provider_tier_intersection','run_count += 1','stopped_at = ""']:
        require(s in svc, f'missing restart/reconfigure behavior {s}')
    require('agent_id, bridge_id, project_id, chain_id, and conversation_id are immutable' in svc and '.Conflict' in svc, 'immutable instance fields must be rejected with conflict')
    require('support.provider != "" && provider != support.provider' in svc and 'support.tier != "" && tier != support.tier' in svc, 'provider/tier must be validated against support policy intersection')
    require('bridge_runtime_registry_has_live' in svc and 'pinned bridge is offline' in svc, 'restart must require pinned live bridge')
    require('launch_command_json(command_id, next)' in svc, 'restart/reconfigure must replay bootstrap via launch command')
    require('private_conversation' in svc and 'conversation_id = conversation_id' in svc and 'write_bootstrap_messages' in svc, 'HBR-24 requires private chain creation and chain/conversation-aware bootstrap')
    require('chain_id' in svc and 'conversation_id' in svc and 'launch_command_json' in svc, 'launch payload must include immutable chain/conversation ids')
    for route in ['"POST", "/api/v1/agent-instances/*/restart"','"PATCH", "/api/v1/agent-instances/*"']:
        require(route in wiring, f'missing route {route}')
    for s in ['restart_agent_instance_handler','patch_agent_instance_handler','reconfigure_input_from_body','has_agent_id','has_bridge_id','has_project_id']:
        require(s in handlers, f'missing handler/parser {s}')
    require('restart_idle_conversation_instance' in content_handlers and 'agent_service.restart_instance' in content_handlers and 'inst.runtime_status=="idle" || inst.runtime_status=="stopped"' in content_handlers, 'continuing idle/stopped conversation must restart the pinned instance')
    require('agent_service.create_instance' in content_handlers and 'get_conversation_by_instance' in content_handlers, 'first-message chat creation without an instance must create a bound instance conversation')
    require('validate_initial_message' in content_handlers and 'if !sent do return respond_error(send_err' in content_handlers, 'initial-message chat creation must propagate message validation/save errors')
    require('chain_id = chain_id' in svc and 'chain_id = json_string(body, "chain_id")' in handlers, 'system/task-chain launch must bind conversation chain_id')
    taskchains=read('src/hub/service/taskchain/taskchain_service.odin')
    task_handlers=read('src/hub/transport/http/taskchain_handlers.odin')
    require('coordinator_agent_instance_id' in taskchains and 'validate_actor_refs' in taskchains and 'agent_instance_same_chain' in taskchains, 'taskchain actor refs must be concrete same-chain refs')
    require('assignee_ref' in task_handlers and 'reviewer_refs' in task_handlers and 'assignee_agent_instance_id' in task_handlers, 'taskchain API must expose actor refs and filters')
    print('PASS: hub restartable static')
if __name__=='__main__': main()
