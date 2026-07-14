#!/usr/bin/env python3
"""Static regression checks for chat artifact failure feedback and draft preservation."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
UPLOAD = (ROOT / 'src/ui/components/ArtifactUpload.tsx').read_text(encoding='utf-8')
CHAIN = (ROOT / 'src/ui/store/chainViewSlice.ts').read_text(encoding='utf-8')

checks = [
    ('unsupported file error remains actionable', 'Unsupported file. Upload a supported artifact (.md, .png, .jpg, .jpeg, .csv, .html, or .htm).' in UPLOAD),
    ('upload preflight failure messages remain actionable', all(snippet in UPLOAD for snippet in [
        'File is too large. Maximum upload size is 5 MB.',
        'Not connected. Reconnect before uploading an artifact.',
        'Upload failed: daemon did not return an artifact link.',
        'Unsupported clipboard image. Paste a PNG screenshot or image.',
    ])),
    ('chain and guide sends clear drafts only after awaited success and expose send errors', all(snippet in APP for snippet in [
        'await onSend(body);\n      setDraft(\'\');',
        'await dispatch(sendGuideMessage({ body, tempId })).unwrap();',
        'data-debug-id="guide-chat-send-error"',
        'data-debug-id="chain-coordinator-send-error"',
    ])),
    ('direct agent sends preserve drafts on throw and expose send errors', all(snippet in APP for snippet in [
        'await onSendAgentMessage?.(agent.id, body, interrupt);\n      setDraft(\'\');',
        'await ensureSelectedAgentRunning(selectedAgentId);\n      await onSendAgentMessage?.(selectedAgentId, body);\n      setDraft(\'\');',
        'data-debug-id="agent-detail-chat-send-error"',
        'data-debug-id="home-running-agent-chat-send-error"',
    ])),
    ('coordinator optimistic failures remain visible instead of disappearing', all(snippet in CHAIN for snippet in [
        '.addCase(sendCoordinatorMessage.rejected, (state: any, action) => {',
        'sending: false,',
        'deliveryFailedUnixMs: Date.now(),',
        'deliveryError: errorMessage,',
    ])),
]

failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)

print('PASS: chat artifact failure feedback and draft preservation contract')
