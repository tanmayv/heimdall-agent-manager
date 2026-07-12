#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RPC = (ROOT / 'src/daemon/guide_rpc.odin').read_text()
ROUTER = (ROOT / 'src/daemon/rest_router.odin').read_text()
HANDBOOK = (ROOT / 'src/prompts/guide-agent.md').read_text()

checks = [
    ('grant request rpc removed', 'guide_request_user_action' not in RPC),
    ('grant execute rpc removed', 'guide_execute_user_action' not in RPC),
    ('grant state and helpers removed', 'Guide_Action_Grant' not in RPC and 'guide_action_grants' not in RPC and 'guide_action_grant_' not in RPC),
    ('grant approval route removed', 'guide-action-grants' not in ROUTER and 'handle_guide_action_grant_approve' not in ROUTER),
    ('grant audit logs removed', 'GUIDE_ACTION_GRANT' not in RPC),
    ('read-only ui debug rpc preserved', 'guide_ui_debug_status' in RPC and 'guide_ui_debug_action' in RPC),
    ('read-only ui debug actions preserved', 'case "info": path = "/info"' in RPC and 'case "state": path = "/state"' in RPC and 'case "elements": path = "/elements"' in RPC and 'case "logs": path = "/logs"' in RPC),
    ('mutating ui debug actions rejected', 'unsupported or mutating UI debug action; allowed: info, state, elements, logs' in RPC and 'http.post(' not in RPC),
    ('unsupported grant rpc names now fall through to generic unsupported message', 'unsupported guide RPC action' in RPC),
    ('handbook documents honest read-only policy', 'guide_ui_debug_action' in HANDBOOK and 'read-only' in HANDBOOK and 'local developer/debug capability' in HANDBOOK),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: guide grant removal and read-only UI policy')
