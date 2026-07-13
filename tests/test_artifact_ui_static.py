#!/usr/bin/env python3
"""Static regression checks for artifact UI plumbing and safety gates."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
API = (ROOT / 'src/ui/api/daemonApi.ts').read_text(encoding='utf-8')
MARKDOWN = (ROOT / 'src/ui/components/Markdown.tsx').read_text(encoding='utf-8')
MARKDOWN_BODY = (ROOT / 'src/ui/components/MarkdownBody.tsx').read_text(encoding='utf-8')
VIEWER = (ROOT / 'src/ui/components/ArtifactViewer.tsx').read_text(encoding='utf-8')
MESSAGE_BUBBLE = (ROOT / 'src/ui/components/MessageBubble.tsx').read_text(encoding='utf-8')

checks = [
    ('artifact API helpers exported', all(snippet in API for snippet in [
        'export async function createArtifact',
        'export async function fetchArtifactMeta',
        'export function artifactContentUrl',
        'export async function listArtifacts',
        'export async function updateArtifact',
        'export async function deleteArtifact',
    ])),
    ('markdown body owns shared renderer', 'export default function MarkdownBody' in MARKDOWN_BODY and 'export function renderMarkdown' in MARKDOWN_BODY),
    ('artifact chip debug id rendered by shared markdown renderer', 'data-debug-id="artifact-chip-${artifactId}"' in MARKDOWN_BODY and 'data-artifact-id="${artifactId}"' in MARKDOWN_BODY),
    ('main Markdown wrapper opens artifact viewer', 'ArtifactViewer' in MARKDOWN and 'onArtifactClick={setActiveArtifactId}' in MARKDOWN),
    ('message bubbles use shared Markdown component', 'return <Markdown source={text} compact' in MESSAGE_BUBBLE),
    ('artifact viewer debug ids present', 'data-debug-id="artifact-viewer"' in VIEWER and 'data-debug-id="artifact-viewer-download-btn"' in VIEWER),
    ('artifact viewer uses shared markdown renderer for markdown artifacts', 'import MarkdownBody from \"./MarkdownBody\"' in VIEWER or "import MarkdownBody from './MarkdownBody'" in VIEWER and '<MarkdownBody source={textContent}' in VIEWER),
    ('html artifacts use sandboxed iframe only', 'sandbox="allow-downloads allow-forms allow-modals allow-pointer-lock allow-popups allow-popups-to-escape-sandbox allow-presentation allow-same-origin allow-scripts"' in VIEWER),
    ('csv preview exists with truncation guard', 'function ArtifactCsvPreview' in VIEWER and 'Preview truncated to 50 rows.' in VIEWER),
    ('nested artifact chips are supported inside artifact markdown previews', 'const [nestedArtifactId, setNestedArtifactId]' in VIEWER and 'onArtifactClick={setNestedArtifactId}' in VIEWER),
]

failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)

print('PASS: artifact UI static contract')
