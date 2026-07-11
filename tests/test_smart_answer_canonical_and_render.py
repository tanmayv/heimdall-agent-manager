#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
svc = (ROOT / 'src/daemon/chat_approval_service.odin').read_text()
rpc = (ROOT / 'src/daemon/agent_rpc.odin').read_text()
app = (ROOT / 'src/ui/components/App.tsx').read_text()
task_service = (ROOT / 'src/daemon/task_service.odin').read_text()

checks = [
    ('canonical smart_answer is documented/detected', '"smart_answer"' in svc and 'kind != "smart_answer"' in svc),
    ('smartanswer typo is rejected, not normalized', 'invalid approval type \'smartanswer\'; use canonical type \'smart_answer\'' in svc and 'kind == "smartanswer" do kind = "smart_answer"' not in svc),
    ('send_to_user returns invalid approval type error before sending', 'chat_approval_invalid_type_error(payload)' in rpc and '"invalid_approval_type"' in svc),
    ('suggested_replies arrays are captured as raw JSON', 'chat_approval_extract_raw_json_value(trimmed, "suggested_replies")' in svc),
    ('coordinator chat renders smart_answer cards', 'parseCoordinatorSmartAnswer' in app and 'chain-coordinator-smart-answer-' in app and 'Needs approval' in app),
    ('smart_answer reply buttons send through coordinator chat', 'onReply={(reply) => onSend(reply)}' in app),
    ('chain creation immediately requests coordinator runtime', 'task_runtime_reconcile_chain_coordinator(chain_id, "chain_created", "high")' in task_service),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: canonical smart_answer approval/render behavior')
