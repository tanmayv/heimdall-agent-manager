#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
AGENT_RPC = (ROOT / 'src/daemon/agent_rpc.odin').read_text()
GUIDE_RPC = (ROOT / 'src/daemon/guide_rpc.odin').read_text()
GUIDE_MD = (ROOT / 'src/prompts/guide-agent.md').read_text()

checks = [
    ('agent rpc delegates guide actions', 'guide_rpc_try_handle(client, action, body, from_agent_instance_id)' in AGENT_RPC),
    ('guide rpc actions are prefix-gated', 'strings.has_prefix(action, "guide_")' in GUIDE_RPC),
    ('guide rpc restricted to guide singleton', '!guide_agent_is_singleton(from_agent_instance_id)' in GUIDE_RPC and 'guide RPC actions are restricted to guide@heimdall' in GUIDE_RPC),
    ('guide status action exists', 'action == "guide_status"' in GUIDE_RPC and 'guide_rpc_status_json' in GUIDE_RPC),
    ('guide summary action exists', 'action == "guide_state_summary"' in GUIDE_RPC and 'guide_rpc_state_summary_json' in GUIDE_RPC),
    ('guide list/show chains exist', 'action == "guide_list_chains"' in GUIDE_RPC and 'action == "guide_show_chain"' in GUIDE_RPC),
    ('guide agent runtime actions exist', 'guide_list_agents' in GUIDE_RPC and 'guide_show_agent_runtime' in GUIDE_RPC),
    ('guide projects action exists', 'guide_list_projects' in GUIDE_RPC and 'project_list_json()' in GUIDE_RPC),
    ('guide ui debug read-only bridge exists', 'guide_ui_debug_status' in GUIDE_RPC and 'guide_ui_debug_action' in GUIDE_RPC and 'unsupported or mutating UI debug action' in GUIDE_RPC),
    ('guide rpc is read-only', 'task_service_' not in GUIDE_RPC and 'agent_record_upsert' not in GUIDE_RPC and 'launch_wrapper_detached' not in GUIDE_RPC),
    ('guide handbook documents read-only rpcs', 'guide_state_summary' in GUIDE_MD and 'guide_show_agent_runtime' in GUIDE_MD and 'guide_ui_debug_action' in GUIDE_MD and 'These are read-only' in GUIDE_MD),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: guide read-only RPC backend')
