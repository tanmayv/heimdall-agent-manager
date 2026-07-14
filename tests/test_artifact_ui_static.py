#!/usr/bin/env python3
"""Static regression checks for artifact UI plumbing and annotation affordances."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
API = (ROOT / 'src/ui/api/daemonApi.ts').read_text(encoding='utf-8')
APP = (ROOT / 'src/ui/components/App.tsx').read_text(encoding='utf-8')
PANEL = (ROOT / 'src/ui/components/ChainArtifactsPanel.tsx').read_text(encoding='utf-8')
UPLOAD = (ROOT / 'src/ui/components/ArtifactUpload.tsx').read_text(encoding='utf-8')
MARKDOWN = (ROOT / 'src/ui/components/Markdown.tsx').read_text(encoding='utf-8')
MARKDOWN_BODY = (ROOT / 'src/ui/components/MarkdownBody.tsx').read_text(encoding='utf-8')
VIEWER = (ROOT / 'src/ui/components/ArtifactViewer.tsx').read_text(encoding='utf-8')
MESSAGE_BUBBLE = (ROOT / 'src/ui/components/MessageBubble.tsx').read_text(encoding='utf-8')
ANNOTATIONS = (ROOT / 'src/ui/utils/artifactAnnotations.ts').read_text(encoding='utf-8')

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
    ('chain coordinator upload uses project and chain context', all(snippet in APP for snippet in [
        "const projectId = chain.projectId || chain.project_id || '';",
        "context={{ projectId: projectId, originRef: chain.chainId || '' }}",
    ])),
    ('successful chain upload inserts artifact link into the draft instead of auto-sending', all(snippet in APP for snippet in [
        'onUploaded={(link) => setDraft((current) => appendArtifactLink(current, link))}',
        'if (result.link) setDraft((current) => appendArtifactLink(current, result.link));',
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
        "originKind: originKind || context.originKind || 'chat'",
    ])),
    ('upload component supports clipboard png paste uploads with contextual origin metadata', all(snippet in UPLOAD for snippet in [
        'export type ClipboardUploadResult = { handled: boolean; link: string | null };',
        'function clipboardPngFromEvent(event: any)',
        'export function appendArtifactLink(current: string, link: string)',
        'uploadClipboardImage: (event: any, overrides?: Partial<ArtifactUploadContext>) => Promise<ClipboardUploadResult>;',
        'Unsupported clipboard image. Paste a PNG screenshot or image.',
        "kind: 'png'",
        "mime: 'image/png'",
        "originKind: overrides.originKind || context.originKind || 'clipboard_chat'",
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
    ('chain view renders the project artifacts panel beside coordinator chat', all(snippet in APP for snippet in [
        'import ChainArtifactsPanel from \'./ChainArtifactsPanel\';',
        'xl:grid-cols-[minmax(0,2fr)_minmax(320px,1fr)]',
        '<ChainArtifactsPanel',
        'projectId={projectId}',
        'chainId={chain.chainId}',
    ])),
    ('artifacts panel uses project-scoped list api and viewer', all(snippet in PANEL for snippet in [
        'data-debug-id="chain-artifacts-panel"',
        'daemonApi.listArtifacts({ daemonUrl, clientToken, projectId, limit: 100 })',
        '<ArtifactViewer artifactId={activeArtifactId} daemonUrl={daemonUrl} clientToken={clientToken} onClose={() => setActiveArtifactId(\'\')} />',
        'This chain has no project_id, so project artifact listing is unavailable.',
    ])),
    ('artifacts panel exposes refresh, copy, open, paste, empty, and error debug ids', all(snippet in PANEL for snippet in [
        'data-debug-id="chain-artifacts-refresh-btn"',
        'data-debug-id="chain-artifacts-paste-zone"',
        'data-debug-id="chain-artifacts-paste-error"',
        'data-debug-id="chain-artifacts-empty"',
        'data-debug-id="chain-artifacts-error"',
        'data-debug-id={`chain-artifact-row-${artifactId}`}',
        'data-debug-id={`chain-artifact-copy-btn-${artifactId}`}',
        'data-debug-id={`chain-artifact-open-btn-${artifactId}`}',
    ])),
    ('artifacts panel copy action writes exact artifact links and surfaces toast feedback', all(snippet in PANEL for snippet in [
        'const link = `artifact://${artifactId}`;',
        'navigator?.clipboard?.writeText',
        "title: 'Artifact link copied'",
        "title: 'Copy failed'",
    ])),
    ('artifacts panel rows show identifying metadata', all(snippet in PANEL for snippet in [
        'const detailBits = [kind || \'artifact\', mime, formatBytes(Number(row.size_bytes || 0))].filter(Boolean);',
        "creator ? `creator ${creator}` : ''",
        "originKind ? `origin ${originKind}${originRef ? ` · ${originRef}` : ''}` : ''",
        "updatedAt ? `updated ${updatedAt}` : createdAt ? `created ${createdAt}` : ''",
    ])),
    ('artifacts panel paste handler uploads clipboard_panel artifacts and refreshes the list', all(snippet in PANEL for snippet in [
        "const pasteUpload = useArtifactUpload({ projectId, originRef: chainId || '', originKind: 'clipboard_panel' });",
        "const result = await pasteUpload.uploadClipboardImage(event, { projectId, originKind: 'clipboard_panel', originRef: chainId || '' });",
        "title: 'Artifact created'",
        'refreshArtifacts();',
    ])),
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
    ('chain view text inputs support clipboard image paste with visible errors', all(snippet in APP for snippet in [
        "const composerArtifactUpload = useArtifactUpload({ projectId, originRef: chain.chainId || '', originKind: 'clipboard_chat' });",
        'onPaste={async (event) => {',
        "originKind: 'clipboard_chat'",
        'data-debug-id="chain-coordinator-paste-error"',
        "const taskTextArtifactUpload = useArtifactUpload({ projectId, originRef: chainId || '', originKind: 'clipboard_chain_text' });",
        "originKind: 'clipboard_chain_text'",
        'data-debug-id={`task-detail-nudge-paste-error-${task.taskId}`}',
        'data-debug-id={`task-detail-comment-paste-error-${task.taskId}`}',
    ])),
    ('nested artifact chips are supported inside artifact markdown previews', 'const [nestedArtifactId, setNestedArtifactId]' in VIEWER and 'onArtifactClick={setNestedArtifactId}' in VIEWER),
    ('annotation header affordances expose stable debug ids', all(snippet in VIEWER for snippet in [
        'data-debug-id="artifact-viewer-annotate-toggle"',
        'data-debug-id="artifact-viewer-annotations-panel"',
        'data-debug-id="artifact-viewer-copy-all-annotations-btn"',
        'annotationModeLabel(previewKind, annotationMode)',
    ])),
    ('annotation list item actions expose debug ids for edit copy remove and comment editing', all(snippet in VIEWER for snippet in [
        'data-debug-id={`artifact-viewer-annotation-item-${annotation.annotationId}`}',
        'data-debug-id="artifact-viewer-annotation-comment-input"',
        'data-debug-id="artifact-viewer-annotation-edit-btn"',
        'data-debug-id="artifact-viewer-annotation-copy-btn"',
        'data-debug-id="artifact-viewer-annotation-remove-btn"',
        'updateArtifactAnnotationComment(artifactId, annotationId, comment)',
        'removeArtifactAnnotation(artifactId, annotationId)',
    ])),
    ('unsupported annotation state and empty annotation state are explicit', all(snippet in VIEWER for snippet in [
        'data-debug-id="artifact-viewer-annotation-unavailable"',
        'Annotations are available for Markdown/text and PNG artifacts only.',
        'data-debug-id="artifact-viewer-annotations-empty"',
    ])),
    ('markdown annotation capture hooks are wired through shared markdown renderer', all(snippet in MARKDOWN_BODY for snippet in [
        'export type MarkdownTextSelection = {',
        'onTextSelectionChange?: (selection: MarkdownTextSelection | null) => void;',
        'window.getSelection?.() || document.getSelection?.()',
        "root.addEventListener('mouseup', emitSelection);",
    ]) and 'onTextSelectionChange={annotationMode ? handleTextSelectionChange : undefined}' in VIEWER),
    ('markdown annotations save selected text with best-effort line and char context', all(snippet in VIEWER for snippet in [
        'selectedText: string;',
        'lineStart?: number;',
        'lineEnd?: number;',
        'charStart?: number;',
        'charEnd?: number;',
        'deriveTextSelectionContext(textContent, selection)',
        'data-debug-id="artifact-viewer-add-annotation-btn"',
        'data-debug-id="artifact-viewer-add-annotation-comment-input"',
        'data-debug-id="artifact-viewer-text-selection-summary"',
        'window.getSelection?.()?.removeAllRanges();',
        'saveArtifactAnnotation(annotation)',
    ])),
    ('png bounding-box annotation capture ui is wired in artifact viewer', all(snippet in VIEWER for snippet in [
        'data-debug-id="artifact-viewer-png-annotation-layer"',
        'data-debug-id="artifact-viewer-png-annotation-panel"',
        'data-debug-id="artifact-viewer-png-region-summary"',
        'data-debug-id="artifact-viewer-add-image-annotation-btn"',
        'data-debug-id="artifact-viewer-clear-image-region-btn"',
        'data-debug-id="artifact-viewer-image-annotation-comment-input"',
        'onPointerDown={handlePointerDown}',
        'onPointerMove={handlePointerMove}',
        'onPointerUp={handlePointerUp}',
        'handleCreateImageRegion',
        "type: 'image'",
    ])),
    ('png annotations persist image-space and percent bbox and render overlays', all(snippet in VIEWER for snippet in [
        'artifact-viewer-png-annotation-overlay-',
        'imageNaturalWidth',
        'imageNaturalHeight',
        'xPercent: pendingImageRegion.xPercent',
        'yPercent: pendingImageRegion.yPercent',
        'wPercent: pendingImageRegion.wPercent',
        'hPercent: pendingImageRegion.hPercent',
        'naturalWidth',
    ])),
    ('annotation store persists locally and is namespaced by artifact id', all(snippet in ANNOTATIONS for snippet in [
        "export const ARTIFACT_ANNOTATIONS_STORAGE_KEY = 'heimdall.artifact.annotations.v1';",
        'byArtifactId: Record<string, ArtifactAnnotationRecord[]>;',
        'window.localStorage.getItem(ARTIFACT_ANNOTATIONS_STORAGE_KEY)',
        'window.localStorage.setItem(ARTIFACT_ANNOTATIONS_STORAGE_KEY, JSON.stringify(store))',
        'export function listArtifactAnnotations(artifactId: string)',
        'export function saveArtifactAnnotation(annotation: ArtifactAnnotationRecord)',
        'export function removeArtifactAnnotation(artifactId: string, annotationId: string)',
    ])),
    ('annotation copy helpers emit portable markdown for single and all annotations', all(snippet in ANNOTATIONS for snippet in [
        'Artifact annotation on [${artifactName}](${artifactUri})',
        'Context:',
        'Comment:',
        'export function formatAllAnnotationsMarkdown(annotations: ArtifactAnnotationRecord[])',
        "join('\\n\\n---\\n\\n')",
        'export async function copyTextToClipboard(text: string)',
        "document.execCommand('copy')",
    ])),
    ('annotation store emits text location and image region context in copied markdown', all(snippet in ANNOTATIONS for snippet in [
        '- location: lines ${annotation.context.lineStart}-${annotation.context.lineEnd}',
        '- selection: ${quoteSelection(annotation.context.selectedText)}',
        '- region: x=${formatNumber(annotation.context.x)} y=${formatNumber(annotation.context.y)} w=${formatNumber(annotation.context.w)} h=${formatNumber(annotation.context.h)}',
        '- region_percent: x=${formatPercent(annotation.context.xPercent)} y=${formatPercent(annotation.context.yPercent)} w=${formatPercent(annotation.context.wPercent)} h=${formatPercent(annotation.context.hPercent)}',
    ])),
    ('annotation context model is discriminated and extensible for future non-text types', all(snippet in ANNOTATIONS for snippet in [
        "type: 'text';",
        "type: 'image';",
        'export type ArtifactAnnotationContext = TextAnnotationContext | ImageAnnotationContext;',
        'function normalizeContext(',
    ]) and all(snippet in VIEWER for snippet in [
        'type NormalizedRegion',
        'function RegionAnnotationLayer',
        "annotation.context.type === 'image'",
    ])),
]

failed = [name for name, ok in checks if not ok]
if failed:
    print('FAILED:')
    for name in failed:
        print('-', name)
    sys.exit(1)

print('PASS: artifact UI static contract and annotation affordances')
