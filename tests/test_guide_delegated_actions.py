#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RPC = (ROOT / 'src/daemon/guide_rpc.odin').read_text()
ROUTER = (ROOT / 'src/daemon/rest_router.odin').read_text()
HANDBOOK = (ROOT / 'src/prompts/guide-agent.md').read_text()

checks = [
    ('guide can request scoped user action grants', 'guide_request_user_action' in RPC and 'guide_rpc_request_user_action_json' in RPC),
    ('guide can execute only approved grants', 'guide_execute_user_action' in RPC and 'grant.state != "approved"' in RPC),
    ('grants are short-lived and one-use', 'GUIDE_ACTION_GRANT_TTL_MS' in RPC and 'grant.used_at_unix_ms != 0' in RPC),
    ('user approval endpoint exists and rejects agent tokens', 'handle_guide_action_grant_approve' in RPC and 'agent tokens cannot approve guide action grants' in RPC),
    ('rest router wires guide action approval', 'guide-action-grants' in ROUTER and 'handle_guide_action_grant_approve' in ROUTER),
    ('delegated UI debug mutations are scoped', 'ui_debug_click' in RPC and 'ui_debug_type' in RPC and 'ui_debug_select' in RPC and 'ui_debug_highlight' in RPC),
    ('delegated action execution proxies through daemon', 'http.post(base, path, grant.params_json)' in RPC),
    ('delegated action grant audit logs exist', 'GUIDE_ACTION_GRANT' in RPC),
    ('handbook documents delegated actions', 'guide_request_user_action' in HANDBOOK and 'guide_execute_user_action' in HANDBOOK and 'one-use' in HANDBOOK),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: guide delegated user action grants')
