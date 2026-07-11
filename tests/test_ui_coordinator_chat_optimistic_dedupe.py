#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
CHAIN = (ROOT / 'src/ui/store/chainViewSlice.ts').read_text(encoding='utf-8')

checks = [
    ('optimistic coordinator messages are stored immediately', 'optimisticCoordinatorMessage(state: any, action)' in CHAIN and 'sending: true' in CHAIN),
    ('fulfilled coordinator sends preserve local message and attach real message id', 'message_id: messageId || m.id' in CHAIN and 'sending: false' in CHAIN),
    ('coordinator message normalization dedupes by message id', 'const deduped = new Map<string, CoordinatorMessage>();' in APP),
    ('coordinator message normalization merges duplicates instead of rendering twice', 'deduped.set(messageId, {' in APP and 'sending: current.sending && next.sending' in APP),
]

failed = [label for (label, ok) in checks if not ok]
if failed:
    print('FAILED:')
    for label in failed:
        print('-', label)
    sys.exit(1)
print('TEST PASSED: coordinator optimistic chat dedupe')
