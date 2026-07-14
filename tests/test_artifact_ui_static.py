#!/usr/bin/env python3
"""Static regression checks for artifact UI plumbing and safety gates."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
API = (ROOT / 'src/ui/api/daemonApi.ts').read_text(encoding='utf-8')
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
UPLOAD = (ROOT / 'src/ui/components/ArtifactUpload.tsx').read_text(encoding='utf-8')
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
    ('artifact creation forwards chat origin metadata', all(snippet in API for snippet in [
        "originKind = ''",
        "originRef = ''",
        'if (originKind) body.origin_kind = originKind;',
        'if (originRef) body.origin_ref = originRef;',
    ])),
    ('chain coordinator composer renders artifact upload affordance and debug ids', all(snippet in APP for snippet in [
        'data-debug-id="chain-coordinator-composer-input"',
        '<ArtifactUploadButton',
        'debugIdPrefix="chain-coordinator-artifact-upload"',
        'label="Attach"',
    ])),
    ('chain coordinator upload uses project and chain context', "context={{ projectId: chain.projectId || chain.project_id || '', originRef: chain.chainId || '' }}" in APP),
    ('successful chain upload inserts artifact link into the draft instead of auto-sending', all(snippet in APP for snippet in [
        'onUploaded={(link) => setDraft((current) => {',
        "return trimmed ? `${trimmed}\\n${link}` : link;",
        'onClick={submit}',
    ])),
    ('upload component only accepts markdown and png files', all(snippet in UPLOAD for snippet in [
        "const MARKDOWN_EXTENSIONS = ['.md', '.markdown'];",
        "const PNG_EXTENSIONS = ['.png'];",
        "export const ARTIFACT_UPLOAD_ACCEPT = '.md,.markdown,text/markdown,.png,image/png';",
    ])),
    ('upload component validates supported files, size, and session before artifact creation', all(snippet in UPLOAD for snippet in [
        'Unsupported file. Upload a Markdown (.md) or PNG (.png) file.',
        'File is too large. Maximum upload size is 5 MB.',
        'Not connected. Reconnect before uploading an artifact.',
        'const res = await daemonApi.createArtifact({',
        "originKind: 'chat'",
    ])),
    ('upload component surfaces inline error state and only calls onUploaded on success', all(snippet in UPLOAD for snippet in [
        'data-debug-id={`${debugIdPrefix}-error`}',
        'const link = await uploadFile(file);',
        'if (link) onUploaded(link);',
    ])),
    ('markdown body owns shared renderer', 'export default function MarkdownBody' in MARKDOWN_BODY and 'export function renderMarkdown' in MARKDOWN_BODY),
    ('artifact chip debug id rendered by shared markdown renderer', 'data-debug-id="artifact-link-chip-${artifactId}"' in MARKDOWN_BODY and 'data-artifact-id="${artifactId}"' in MARKDOWN_BODY),
    ('artifact chip labels are resolved from artifact metadata with id fallback', all(snippet in MARKDOWN_BODY for snippet in [
        'artifactNameCache',
        'fetchArtifactMeta({ daemonUrl, clientToken, artifactId })',
        "const name = String(data?.artifact?.name || '');",
    ])),
    ('main Markdown wrapper opens artifact viewer', 'ArtifactViewer' in MARKDOWN and 'onArtifactClick={setActiveArtifactId}' in MARKDOWN),
    ('non-artifact markdown links still render normally', all(snippet in MARKDOWN_BODY for snippet in [
        '<a href="${url}" target="_blank" rel="noreferrer"',
        r'\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)',
    ])),
    ('message bubbles use shared Markdown component', 'return <Markdown source={text} compact' in MESSAGE_BUBBLE),
    ('artifact viewer debug ids present', all(snippet in VIEWER for snippet in [
        'data-debug-id="artifact-viewer"',
        'data-debug-id="artifact-viewer-download-btn"',
        'data-debug-id="artifact-viewer-close-btn"',
        'data-debug-id="artifact-viewer-markdown-preview"',
        'data-debug-id="artifact-viewer-png-preview"',
        'data-debug-id="artifact-viewer-unsupported-preview"',
    ])),
    ('artifact viewer uses shared markdown renderer for markdown artifacts', ('import MarkdownBody from "./MarkdownBody"' in VIEWER or "import MarkdownBody from './MarkdownBody'" in VIEWER) and 'source={textContent}' in VIEWER),
    ('artifact viewer preview classification is markdown/png/unsupported only', "type PreviewKind = 'markdown' | 'png' | 'unsupported';" in VIEWER and "return 'unsupported';" in VIEWER),
    ('unsupported previews show clear fallback text', 'Preview is not available for this artifact type' in VIEWER),
    ('nested artifact chips are supported inside artifact markdown previews', 'const [nestedArtifactId, setNestedArtifactId]' in VIEWER and 'onArtifactClick={setNestedArtifactId}' in VIEWER),
]

failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)

print('PASS: artifact UI static contract')
