#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text()
CHAT = (ROOT / 'src/ui/store/chatSlice.ts').read_text()

checks = [
    ('guide id constant exists', "export const GUIDE_AGENT_ID = 'guide@heimdall';" in CHAT),
    ('guide chat fetch/send thunks exist', 'fetchGuideChat' in CHAT and 'sendGuideMessage' in CHAT and 'agentInstanceId: GUIDE_AGENT_ID' in CHAT),
    ('guide panel state actions exist', 'guidePanelOpen' in CHAT and 'toggleGuidePanel' in CHAT and 'closeGuidePanel' in CHAT),
    ('floating helmet button exists', 'data-debug-id="guide-floating-btn"' in APP and '🪖' in APP),
    ('guide panel is flex sibling not overlay', 'data-debug-id="guide-side-panel-slot"' in APP and 'transition-[width]' in APP and "guidePanelOpen ? 'w-[400px]' : 'w-0'" in APP),
    ('guide side panel exists with composer', 'data-debug-id="guide-side-panel"' in APP and 'data-debug-id="guide-chat-composer-input"' in APP and 'data-debug-id="guide-chat-send-btn"' in APP),
    ('guide panel reuses coordinator message list', 'debugPrefix="guide-chat"' in APP and 'emptyText="No guide chat yet.' in APP),
    ('coordinator message list remains defaulted for coordinator', "debugPrefix = 'chain-coordinator'" in APP and "emptyText = 'No coordinator chat loaded for this chain.'" in APP),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: guide panel UI scaffolding')
