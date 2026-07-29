#!/usr/bin/env python3
"""Static checks for chat and task-comment artifact upload surfaces."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
CHAT = (ROOT / 'src/ui/components/chat/ConversationThreadPage.tsx').read_text(encoding='utf-8')
TASK = (ROOT / 'src/ui/components/taskchain/TaskChainOverview.tsx').read_text(encoding='utf-8')
UTIL = (ROOT / 'src/ui/utils/artifactUpload.ts').read_text(encoding='utf-8')
DAEMON = (ROOT / 'src/ui/api/daemonApi.ts').read_text(encoding='utf-8')
ARTIFACT_ENDPOINTS = (ROOT / 'src/ui/api/endpoints/artifacts.ts').read_text(encoding='utf-8')

checks = [
    ('shared upload helpers preserve text paste unless clipboard files exist', all(snippet in UTIL for snippet in [
        'export function clipboardFilesFromEvent',
        'Array.from(data?.files || [])',
        'Array.from(data?.items || [])',
        "item?.kind === 'file'",
        'return out;',
    ])),
    ('shared upload helpers derive compatible artifact metadata and links', all(snippet in UTIL for snippet in [
        'export function artifactKindForFile',
        "mime.startsWith('image/')",
        "return 'markdown';",
        "return 'file';",
        'export function artifactLinkFromResponse',
        "return id ? `artifact://${id}` : '';",
        'export function appendArtifactLinks',
    ])),
    ('conversation composer has file button upload plus paste image/file upload', all(snippet in CHAT for snippet in [
        'data-debug-id="conversation-attach-btn"',
        'data-debug-id="conversation-attach-input"',
        'function handleComposerPaste',
        'const files = clipboardFilesFromEvent(event);',
        'if (files.length === 0) return;',
        'event.preventDefault();',
        'onPaste={handleComposerPaste}',
    ]) and CHAT.count('onPaste={handleComposerPaste}') == 2),
    ('conversation uploads persist artifact ids with progress retry and send gating', all(snippet in CHAT for snippet in [
        'useCreateArtifactMutation',
        "originKind: 'conversation_chat'",
        'artifactKindForFile(file)',
        'artifactMimeForFile(file)',
        'artifactLinkFromResponse(res)',
        'data-debug-id="conversation-attachment-tray"',
        'data-debug-id={`conversation-attachment-progress-${a.localId}`}',
        'data-debug-id={`conversation-attachment-retry-${a.localId}`}',
        'sendMessage({ conversationId, body: sendBody, artifactIds: attachmentIds })',
        "title={hasUploadingAttachments ? 'Wait for uploads to finish before sending'",
    ])),
    ('task comments have upload button paste handling progress retry and disabled send states', all(snippet in TASK for snippet in [
        'useCreateArtifactMutation',
        'const uploadCommentAttachment = async',
        "originKind: 'task_comment'",
        'artifactKindForFile(file)',
        'artifactMimeForFile(file)',
        'artifactLinkFromResponse(res)',
        'const handleCommentPaste',
        'clipboardFilesFromEvent(event)',
        'data-debug-id={`taskchain-task-comment-attach-btn-${taskId}`}',
        'data-debug-id={`taskchain-task-comment-attach-input-${taskId}`}',
        'data-debug-id={`taskchain-task-comment-attachment-tray-${taskId}`}',
        'data-debug-id={`taskchain-task-comment-attachment-progress-${taskId}-${attachment.localId}`}',
        'data-debug-id={`taskchain-task-comment-attachment-retry-${taskId}-${attachment.localId}`}',
        'disabled={!taskCommentCanSend}',
        "title={taskCommentUploading ? 'Wait for uploads to finish before sending'",
    ])),
    ('task comments persist durable artifact links and render uploaded attachments', all(snippet in TASK for snippet in [
        'appendArtifactLinks(text, attachments.filter',
        'await addComment({ chainId, taskId, body }).unwrap();',
        'artifactIdsFromText(comment.body || \'\')',
        '<ArtifactAttachmentPreview',
        "session={{ daemonUrl: '', clientToken: '' }}",
        '<Markdown source={comment.body || \'\'} compact copyAll={false}',
    ])),
    ('artifact file uploads avoid multipart load-failed path and preserve mime/ext metadata', all(snippet in DAEMON + ARTIFACT_ENDPOINTS for snippet in [
        'function blobToBase64(blob: Blob): Promise<string>',
        'reader.readAsDataURL(blob);',
        'const uploadBase64 = file ? await blobToBase64(file) : contentBase64;',
        'content_base64: uploadBase64,',
        'function extensionFromNameOrMime',
        'if (finalExt) body.ext = finalExt;',
        'timeoutMs: 120000,',
        'ext?: string;',
    ]) and 'requestFormJson(joinUrl(daemonUrl, \'/api/v1/artifacts\')' not in DAEMON),
]

failures = [name for name, ok in checks if not ok]
if failures:
    for name in failures:
        print(f'FAIL: {name}', file=sys.stderr)
    sys.exit(1)
print(f'PASS: {len(checks)} artifact upload surface checks')
