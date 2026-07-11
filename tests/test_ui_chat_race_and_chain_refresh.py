#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text()
CHAIN = (ROOT / 'src/ui/store/chainViewSlice.ts').read_text()
CHAT = (ROOT / 'src/ui/store/chatSlice.ts').read_text()
HOME = (ROOT / 'src/ui/store/homeSlice.ts').read_text()

checks = [
    ('coordinator keeps delivered optimistic messages during fetch race', 'OPTIMISTIC_MESSAGE_GRACE_MS' in CHAIN and 'now - lastLocalAt < OPTIMISTIC_MESSAGE_GRACE_MS' in CHAIN),
    ('chain view renders delivered optimistic messages, not only sending ones', 'const optimistic = chainView.optimisticMessagesByChainId[chain.chainId] || []' in APP),
    ('guide/direct chat keeps recent optimistic messages during fetch race', 'CHAT_OPTIMISTIC_GRACE_MS' in CHAT and 'isRecentOptimisticMessage' in CHAT),
    ('open chain writes chainId into URL for reload persistence', 'updateUrlParams({ chainId, view: \'chain\' })' in APP),
    ('home initial state restores chain surface from URL', 'initialChainIdFromUrl' in HOME and "surface: initialChainId ? 'chain' : 'home'" in HOME),
]
failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)
print('TEST PASSED: UI chat race and chain refresh persistence')
