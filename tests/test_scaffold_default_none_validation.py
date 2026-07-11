#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text()
HOME = (ROOT / 'src/ui/store/homeSlice.ts').read_text()
TASK = (ROOT / 'src/daemon/task_service.odin').read_text()
NUDGE = (ROOT / 'src/daemon/task_nudge_scheduler.odin').read_text()

checks = [
    ('new chain scaffold defaults to none', "const [scaffold, setScaffold] = useState('none');" in APP and "setScaffold('none');" in APP),
    ('goal is only rendered for non-none scaffold', "{scaffold !== 'none' && (" in APP and 'new-chain-goal-textarea' in APP),
    ('team kind description is visible in modal', 'data-debug-id="new-chain-kind-description"' in APP and 'kindDef.description' in APP),
    ('hidden goal is not submitted for no scaffold', "description: payload.scaffold && payload.scaffold !== 'none' ? (payload.goal || '') : ''" in HOME),
    ('backend treats none as no scaffold', 'cmd.scaffold != "none"' in TASK and 'scaffold_selected :=' in TASK),
    ('coordinator task name depends on scaffold mode', '"Validate task chain scaffold" if scaffold_selected else "Update task chain from user requirement"' in TASK),
    ('scaffold tasks depend on coordinator validation task', 'validation_task_id != ""' in TASK and 'strings.write_string(&deps, validation_task_id)' in TASK),
    ('chain creation immediately requests coordinator start and returns evidence', 'coordinator_boot_requested := task_runtime_reconcile_chain_coordinator(chain_id, "chain_created", "high")' in TASK and '"coordinator_boot_requested"' in TASK),
    ('chain_created coordinator boot bypasses team boot lease throttling', 'reason == "chain_created"' in NUDGE),
    ('ui progress marks coordinator start requested from create response', 'coordinatorBootRequested' in APP and 'Coordinator start requested' in APP),
]
failed = [label for label, ok in checks if not ok]
if failed:
    print('FAILED:')
    for label in failed:
        print('-', label)
    sys.exit(1)
print('TEST PASSED: scaffold default none and validation gate')
