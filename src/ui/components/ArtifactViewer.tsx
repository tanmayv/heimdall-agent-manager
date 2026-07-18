import { useEffect, useMemo, useRef, useState } from 'react';
import { useArtifactContentUrl, useFetchArtifactMetaQuery, useFetchArtifactTextContentQuery } from '../api/endpoints/artifacts';
import {
  copyTextToClipboard,
  createArtifactAnnotation,
  formatAllAnnotationsMarkdown,
  formatAnnotationMarkdown,
  listArtifactAnnotations,
  removeArtifactAnnotation,
  saveArtifactAnnotation,
  summarizeAnnotationContext,
  type ArtifactAnnotationRecord,
  updateArtifactAnnotationComment,
} from '../utils/artifactAnnotations';
import MarkdownBody from './MarkdownBody';
import type { MarkdownTextSelection } from './MarkdownBody';

type ArtifactViewerProps = {
  artifactId: string;
  daemonUrl: string;
  clientToken: string;
  onClose: () => void;
};

type ArtifactMeta = {
  artifact_id: string;
  name: string;
  kind: string;
  mime: string;
  ext: string;
  size_bytes: number;
  sha256: string;
  description: string;
  project_id: string;
  creator_type: string;
  creator_id: string;
  origin_kind: string;
  origin_ref: string;
  created_unix_ms: number;
  updated_unix_ms: number;
  deleted: boolean;
  link: string;
  renderer?: string;
};

type PreviewKind = 'markdown' | 'png' | 'unsupported';
type CopyState = 'idle' | 'copied' | 'error';

function formatBytes(value: number) {
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let size = value;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }
  return `${size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[unit]}`;
}

function classifyPreview(meta: ArtifactMeta | null): PreviewKind {
  if (!meta) return 'unsupported';
  const kind = String(meta.kind || '').toLowerCase();
  const mime = String(meta.mime || '').toLowerCase();
  const ext = String(meta.ext || '').toLowerCase();
  if (kind === 'markdown' || kind === 'text' || mime === 'text/markdown' || mime === 'text/plain' || ext === '.md' || ext === '.markdown' || ext === '.txt') {
    return 'markdown';
  }
  if (kind === 'png' || mime === 'image/png' || ext === '.png') {
    return 'png';
  }
  return 'unsupported';
}

function annotationModeLabel(previewKind: PreviewKind, annotationMode: boolean) {
  if (!annotationMode) return 'Annotate';
  if (previewKind === 'markdown') return 'Annotating text';
  if (previewKind === 'png') return 'Annotating image';
  return 'Annotations unavailable';
}

function supportedAnnotationHint(previewKind: PreviewKind, annotationMode: boolean) {
  if (previewKind === 'markdown') {
    return annotationMode
      ? 'Annotation mode is on. Select text in the preview, add a comment, and save the annotation.'
      : 'Turn on Annotate to start marking up this Markdown/text artifact.';
  }
  if (previewKind === 'png') {
    return annotationMode
      ? 'Annotation mode is on. Drag on the image to create a bounding-box annotation when image capture is active.'
      : 'Turn on Annotate to start marking up this PNG artifact.';
  }
  return 'Annotations are available for Markdown/text and PNG artifacts only.';
}

type PendingTextAnnotation = {
  selectedText: string;
  lineStart?: number;
  lineEnd?: number;
  charStart?: number;
  charEnd?: number;
};

function normalizeSelectionText(value: string) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

function buildWhitespaceNormalizedIndex(value: string) {
  let normalized = '';
  const rawIndexByNormalizedIndex: number[] = [];
  let previousWasWhitespace = false;
  for (let index = 0; index < value.length; index += 1) {
    const char = value[index];
    const isWhitespace = /\s/.test(char);
    if (isWhitespace) {
      if (!previousWasWhitespace) {
        normalized += ' ';
        rawIndexByNormalizedIndex.push(index);
      }
      previousWasWhitespace = true;
      continue;
    }
    normalized += char;
    rawIndexByNormalizedIndex.push(index);
    previousWasWhitespace = false;
  }
  return { normalized, rawIndexByNormalizedIndex };
}

function deriveTextSelectionContext(source: string, selection: MarkdownTextSelection | null): PendingTextAnnotation | null {
  const selectedText = normalizeSelectionText(selection?.selectedText || '');
  if (!selectedText) return null;

  let charStart = source.indexOf(selectedText);
  let charEnd = charStart >= 0 ? charStart + selectedText.length : -1;

  if (charStart < 0) {
    const normalizedSource = buildWhitespaceNormalizedIndex(source);
    const normalizedSelection = normalizeSelectionText(selectedText);
    const normalizedIndex = normalizedSource.normalized.indexOf(normalizedSelection);
    if (normalizedIndex >= 0) {
      charStart = normalizedSource.rawIndexByNormalizedIndex[normalizedIndex] ?? -1;
      const endIndex = normalizedIndex + normalizedSelection.length - 1;
      const rawEndIndex = normalizedSource.rawIndexByNormalizedIndex[endIndex];
      charEnd = rawEndIndex != null ? rawEndIndex + 1 : -1;
    }
  }

  const context: PendingTextAnnotation = { selectedText };
  if (charStart >= 0 && charEnd >= charStart) {
    context.charStart = charStart;
    context.charEnd = charEnd;
    context.lineStart = source.slice(0, charStart).split('\n').length;
    context.lineEnd = source.slice(0, charEnd).split('\n').length;
  }
  return context;
}

function summarizePendingTextAnnotation(selection: PendingTextAnnotation | null) {
  if (!selection) return 'Select text in the Markdown preview to begin a text annotation.';
  const summaryParts: string[] = [];
  if (selection.lineStart && selection.lineEnd && selection.lineStart !== selection.lineEnd) {
    summaryParts.push(`Lines ${selection.lineStart}-${selection.lineEnd}`);
  } else if (selection.lineStart) {
    summaryParts.push(`Line ${selection.lineStart}`);
  }
  summaryParts.push(`“${selection.selectedText}”`);
  return summaryParts.join(' · ');
}

// Region drawn on a PNG, expressed as container-relative percentages so it can
// be reprojected against any rendered image size on reopen/resizing. This is a
// generic normalized rectangle so future non-text visual contexts (e.g. HTML
// element bounding regions) can reuse the same draft/adapter shape (ANN-15).
type NormalizedRegion = {
  xPercent: number;
  yPercent: number;
  wPercent: number;
  hPercent: number;
};

function clampPercent(value: number) {
  if (!Number.isFinite(value)) return 0;
  return Math.min(100, Math.max(0, value));
}

type RegionAnnotationLayerProps = {
  contentUrl: string;
  alt: string;
  annotationMode: boolean;
  annotations: ArtifactAnnotationRecord[];
  onCreateRegion: (region: NormalizedRegion, naturalWidth: number, naturalHeight: number) => void;
};

// Reusable overlay/drawing adapter for image-space rectangle annotations. It is
// intentionally decoupled from PNG-only assumptions: it renders any persisted
// `image` context and reports normalized regions, so additional raster/visual
// context types can adopt it without changing the common store/panel workflow.
function RegionAnnotationLayer({ contentUrl, alt, annotationMode, annotations, onCreateRegion }: RegionAnnotationLayerProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const [dragStart, setDragStart] = useState<{ x: number; y: number } | null>(null);
  const [dragCurrent, setDragCurrent] = useState<{ x: number; y: number } | null>(null);

  const regionAnnotations = useMemo(
    () => annotations.filter((annotation) => annotation.context.type === 'image'),
    [annotations],
  );

  function toLocalPercent(clientX: number, clientY: number) {
    const rect = containerRef.current?.getBoundingClientRect();
    if (!rect || rect.width === 0 || rect.height === 0) return { x: 0, y: 0 };
    return {
      x: clampPercent(((clientX - rect.left) / rect.width) * 100),
      y: clampPercent(((clientY - rect.top) / rect.height) * 100),
    };
  }

  function handlePointerDown(event: React.PointerEvent<HTMLDivElement>) {
    if (!annotationMode) return;
    event.preventDefault();
    (event.currentTarget as HTMLDivElement).setPointerCapture?.(event.pointerId);
    const point = toLocalPercent(event.clientX, event.clientY);
    setDragStart(point);
    setDragCurrent(point);
  }

  function handlePointerMove(event: React.PointerEvent<HTMLDivElement>) {
    if (!annotationMode || !dragStart) return;
    setDragCurrent(toLocalPercent(event.clientX, event.clientY));
  }

  function handlePointerUp(event: React.PointerEvent<HTMLDivElement>) {
    if (!annotationMode || !dragStart) return;
    const end = toLocalPercent(event.clientX, event.clientY);
    const xPercent = Math.min(dragStart.x, end.x);
    const yPercent = Math.min(dragStart.y, end.y);
    const wPercent = Math.abs(end.x - dragStart.x);
    const hPercent = Math.abs(end.y - dragStart.y);
    setDragStart(null);
    setDragCurrent(null);
    if (wPercent < 1 || hPercent < 1) return;
    const image = imageRef.current;
    onCreateRegion({ xPercent, yPercent, wPercent, hPercent }, image?.naturalWidth || 0, image?.naturalHeight || 0);
  }

  const draftRect = dragStart && dragCurrent
    ? {
        left: Math.min(dragStart.x, dragCurrent.x),
        top: Math.min(dragStart.y, dragCurrent.y),
        width: Math.abs(dragCurrent.x - dragStart.x),
        height: Math.abs(dragCurrent.y - dragStart.y),
      }
    : null;

  return (
    <div
      ref={containerRef}
      data-debug-id="artifact-viewer-png-annotation-layer"
      className="relative inline-block max-w-full"
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      style={{ touchAction: annotationMode ? 'none' : undefined, cursor: annotationMode ? 'crosshair' : undefined }}
    >
      <img
        ref={imageRef}
        data-debug-id="artifact-viewer-png-preview"
        src={contentUrl}
        alt={alt}
        draggable={false}
        className="max-h-[70vh] max-w-full select-none rounded-2xl border border-white/10 bg-black/30"
      />
      <div className="pointer-events-none absolute inset-0">
        {regionAnnotations.map((annotation) => {
          const ctx = annotation.context as Extract<ArtifactAnnotationRecord['context'], { type: 'image' }>;
          return (
            <div
              key={annotation.annotationId}
              data-debug-id={`artifact-viewer-png-annotation-overlay-${annotation.annotationId}`}
              className="absolute rounded border-2 border-emerald-400/80 bg-emerald-400/10"
              style={{
                left: `${clampPercent(ctx.xPercent)}%`,
                top: `${clampPercent(ctx.yPercent)}%`,
                width: `${clampPercent(ctx.wPercent)}%`,
                height: `${clampPercent(ctx.hPercent)}%`,
              }}
            >
              <span className="absolute -top-5 left-0 max-w-[16rem] truncate rounded bg-emerald-400 px-1 text-[10px] font-semibold text-black">
                {annotation.comment.trim().slice(0, 24) || 'note'}
              </span>
            </div>
          );
        })}
        {draftRect ? (
          <div
            data-debug-id="artifact-viewer-png-annotation-draft"
            className="absolute rounded border-2 border-dashed border-sky-300 bg-sky-300/10"
            style={{
              left: `${draftRect.left}%`,
              top: `${draftRect.top}%`,
              width: `${draftRect.width}%`,
              height: `${draftRect.height}%`,
            }}
          />
        ) : null}
      </div>
    </div>
  );
}

type AnnotationListItemProps = {
  annotation: ArtifactAnnotationRecord;
  onRemove: (annotationId: string) => void;
  onSaveComment: (annotationId: string, comment: string) => void;
};

function AnnotationListItem({ annotation, onRemove, onSaveComment }: AnnotationListItemProps) {
  const [copyState, setCopyState] = useState<CopyState>('idle');
  const [isEditing, setIsEditing] = useState(false);
  const [draftComment, setDraftComment] = useState(annotation.comment);

  useEffect(() => {
    setDraftComment(annotation.comment);
  }, [annotation.annotationId, annotation.comment]);

  async function handleCopy() {
    try {
      await copyTextToClipboard(formatAnnotationMarkdown(annotation));
      setCopyState('copied');
      window.setTimeout(() => setCopyState('idle'), 1200);
    } catch {
      setCopyState('error');
      window.setTimeout(() => setCopyState('idle'), 1500);
    }
  }

  function handleSave() {
    onSaveComment(annotation.annotationId, draftComment);
    setIsEditing(false);
  }

  function handleCancel() {
    setDraftComment(annotation.comment);
    setIsEditing(false);
  }

  return (
    <div
      data-debug-id={`artifact-viewer-annotation-item-${annotation.annotationId}`}
      className="rounded-2xl border border-white/10 bg-black/20 p-3"
    >
      <div className="text-xs font-medium uppercase tracking-wide text-zinc-500">{annotation.context.type === 'image' ? 'Image annotation' : 'Text annotation'}</div>
      <div className="mt-1 text-sm text-zinc-300">{summarizeAnnotationContext(annotation)}</div>
      {isEditing ? (
        <div className="mt-3 space-y-2">
          <textarea
            data-debug-id="artifact-viewer-annotation-comment-input"
            value={draftComment}
            onChange={(event) => setDraftComment(event.target.value)}
            rows={4}
            className="w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-sky-400"
            placeholder="Annotation comment"
          />
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              data-debug-id="artifact-viewer-annotation-save-btn"
              onClick={handleSave}
              className="rounded-xl bg-sky-400 px-3 py-2 text-sm font-semibold text-black hover:bg-sky-300"
            >
              Save
            </button>
            <button
              type="button"
              data-debug-id="artifact-viewer-annotation-cancel-btn"
              onClick={handleCancel}
              className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15"
            >
              Cancel
            </button>
          </div>
        </div>
      ) : (
        <div className="mt-3 rounded-xl border border-white/5 bg-white/[0.03] px-3 py-2 text-sm text-zinc-100 whitespace-pre-wrap">
          {annotation.comment.trim() || <span className="text-zinc-500">(empty comment)</span>}
        </div>
      )}
      <div className="mt-3 flex flex-wrap gap-2">
        {!isEditing ? (
          <button
            type="button"
            data-debug-id="artifact-viewer-annotation-edit-btn"
            onClick={() => setIsEditing(true)}
            className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15"
          >
            Edit
          </button>
        ) : null}
        <button
          type="button"
          data-debug-id="artifact-viewer-annotation-copy-btn"
          onClick={handleCopy}
          className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15"
        >
          {copyState === 'copied' ? 'Copied' : copyState === 'error' ? 'Copy failed' : 'Copy'}
        </button>
        <button
          type="button"
          data-debug-id="artifact-viewer-annotation-remove-btn"
          onClick={() => onRemove(annotation.annotationId)}
          className="rounded-xl bg-rose-500/15 px-3 py-2 text-sm text-rose-100 hover:bg-rose-500/25"
        >
          Remove
        </button>
      </div>
    </div>
  );
}

export default function ArtifactViewer({ artifactId, daemonUrl, clientToken, onClose }: ArtifactViewerProps) {
  const metaQuery = useFetchArtifactMetaQuery({ artifactId }, { skip: !artifactId || !clientToken });
  const meta = (metaQuery.data?.artifact || null) as ArtifactMeta | null;
  const [annotations, setAnnotations] = useState<ArtifactAnnotationRecord[]>(() => listArtifactAnnotations(artifactId));
  const [annotationMode, setAnnotationMode] = useState(false);
  const [annotationsOpen, setAnnotationsOpen] = useState(false);
  const [copyAllState, setCopyAllState] = useState<CopyState>('idle');
  const [pendingTextSelection, setPendingTextSelection] = useState<PendingTextAnnotation | null>(null);
  const [newAnnotationComment, setNewAnnotationComment] = useState('');
  const [textAnnotationError, setTextAnnotationError] = useState('');
  const [pendingImageRegion, setPendingImageRegion] = useState<NormalizedRegion | null>(null);
  const [pendingImageNatural, setPendingImageNatural] = useState<{ width: number; height: number }>({ width: 0, height: 0 });
  const [imageAnnotationComment, setImageAnnotationComment] = useState('');
  const [nestedArtifactId, setNestedArtifactId] = useState('');

  const contentUrl = useArtifactContentUrl({ daemonUrl, clientToken, artifactId });

  useEffect(() => {
    setAnnotations(listArtifactAnnotations(artifactId));
    setAnnotationMode(false);
    setAnnotationsOpen(false);
    setCopyAllState('idle');
    setPendingTextSelection(null);
    setNewAnnotationComment('');
    setTextAnnotationError('');
    setPendingImageRegion(null);
    setImageAnnotationComment('');
  }, [artifactId]);

  const previewKind = useMemo(() => classifyPreview(meta), [meta]);
  const annotationSupported = previewKind === 'markdown' || previewKind === 'png';

  useEffect(() => {
    if (previewKind === 'markdown' && annotationMode) return;
    setPendingTextSelection(null);
    setTextAnnotationError('');
  }, [annotationMode, previewKind]);

  useEffect(() => {
    if (previewKind === 'png' && annotationMode) return;
    setPendingImageRegion(null);
    setImageAnnotationComment('');
  }, [annotationMode, previewKind]);

  const textQuery = useFetchArtifactTextContentQuery({ artifactId }, { skip: !artifactId || !clientToken || previewKind !== 'markdown' });
  const textContent = textQuery.data?.text || '';
  const loading = metaQuery.isFetching;
  const loadingText = textQuery.isFetching;
  const error = metaQuery.error ? 'Failed to load artifact metadata.' : textQuery.error ? 'Failed to load artifact content.' : (!loading && !meta ? 'Artifact metadata is unavailable.' : '');

  const title = meta?.name || annotations[0]?.artifactName || artifactId;

  async function handleCopyAll() {
    if (!annotations.length) return;
    try {
      await copyTextToClipboard(formatAllAnnotationsMarkdown(annotations));
      setCopyAllState('copied');
      window.setTimeout(() => setCopyAllState('idle'), 1200);
    } catch {
      setCopyAllState('error');
      window.setTimeout(() => setCopyAllState('idle'), 1500);
    }
  }

  function handleRemoveAnnotation(annotationId: string) {
    setAnnotations(removeArtifactAnnotation(artifactId, annotationId));
  }

  function handleSaveComment(annotationId: string, comment: string) {
    setAnnotations(updateArtifactAnnotationComment(artifactId, annotationId, comment));
  }

  function handleTextSelectionChange(selection: MarkdownTextSelection | null) {
    if (!annotationMode || previewKind !== 'markdown') return;
    setPendingTextSelection(deriveTextSelectionContext(textContent, selection));
    setTextAnnotationError('');
  }

  function handleAddTextAnnotation() {
    if (!meta) return;
    if (!pendingTextSelection?.selectedText) {
      setTextAnnotationError('Select text in the Markdown preview before adding an annotation.');
      return;
    }
    const comment = newAnnotationComment.trim();
    if (!comment) {
      setTextAnnotationError('Add a comment before saving this annotation.');
      return;
    }
    const annotation = createArtifactAnnotation({
      artifactId,
      artifactUri: meta.link || `artifact://${artifactId}`,
      artifactName: meta.name || artifactId,
      artifactMime: meta.mime || 'text/markdown',
      artifactKind: meta.kind || 'markdown',
      comment,
      context: {
        type: 'text',
        selectedText: pendingTextSelection.selectedText,
        lineStart: pendingTextSelection.lineStart,
        lineEnd: pendingTextSelection.lineEnd,
        charStart: pendingTextSelection.charStart,
        charEnd: pendingTextSelection.charEnd,
      },
    });
    setAnnotations(saveArtifactAnnotation(annotation));
    setAnnotationsOpen(true);
    setNewAnnotationComment('');
    setPendingTextSelection(null);
    setTextAnnotationError('');
    window.getSelection?.()?.removeAllRanges();
  }

  function handleCreateImageRegion(region: NormalizedRegion, naturalWidth: number, naturalHeight: number) {
    setPendingImageRegion(region);
    setPendingImageNatural({ width: naturalWidth, height: naturalHeight });
    setImageAnnotationComment('');
    setAnnotationsOpen(true);
  }

  function handleAddImageAnnotation() {
    if (!meta || !pendingImageRegion) return;
    const comment = imageAnnotationComment.trim();
    if (!comment) return;
    const { width, height } = pendingImageNatural;
    const hasNatural = width > 0 && height > 0;
    const annotation = createArtifactAnnotation({
      artifactId,
      artifactUri: meta.link || `artifact://${artifactId}`,
      artifactName: meta.name || artifactId,
      artifactMime: meta.mime || 'image/png',
      artifactKind: meta.kind || 'png',
      comment,
      context: {
        type: 'image',
        x: hasNatural ? Math.round((pendingImageRegion.xPercent / 100) * width) : 0,
        y: hasNatural ? Math.round((pendingImageRegion.yPercent / 100) * height) : 0,
        w: hasNatural ? Math.round((pendingImageRegion.wPercent / 100) * width) : 0,
        h: hasNatural ? Math.round((pendingImageRegion.hPercent / 100) * height) : 0,
        xPercent: pendingImageRegion.xPercent,
        yPercent: pendingImageRegion.yPercent,
        wPercent: pendingImageRegion.wPercent,
        hPercent: pendingImageRegion.hPercent,
        imageNaturalWidth: hasNatural ? width : undefined,
        imageNaturalHeight: hasNatural ? height : undefined,
      },
    });
    setAnnotations(saveArtifactAnnotation(annotation));
    setAnnotationsOpen(true);
    setPendingImageRegion(null);
    setImageAnnotationComment('');
  }

  return (
    <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/75 p-4 backdrop-blur-sm" onClick={onClose}>
      <div data-debug-id="artifact-viewer" className="flex max-h-[92vh] w-full max-w-6xl flex-col overflow-hidden rounded-[22px] border border-white/10 bg-[#0b0d12] shadow-[0_40px_120px_rgba(0,0,0,0.55)]" onClick={(event) => event.stopPropagation()}>
        <div data-debug-id="artifact-viewer-breadcrumb" className="flex items-center gap-2 border-b border-white/[0.06] bg-[#0d0f14]/80 px-5 py-2.5 text-[12px] text-zinc-500">
          <span className="text-zinc-400">Artifact</span>
          <span className="text-zinc-700">/</span>
          <span className="truncate text-zinc-200">{title}</span>
        </div>
        <div className="flex flex-wrap items-start justify-between gap-4 border-b border-white/10 px-5 pb-4 pt-4">
          <div className="min-w-0">
            <div className="truncate text-xl font-semibold tracking-[-0.01em] text-zinc-100">{title}</div>
            <div data-debug-id="artifact-viewer-meta-strip" className="mt-2 flex flex-wrap items-center gap-2 text-[11.5px] text-zinc-400">
              <span className="rounded-full border border-white/10 bg-white/[0.04] px-2.5 py-0.5 uppercase tracking-wide text-zinc-300">{meta?.kind || 'artifact'}</span>
              {meta?.mime && <span className="rounded-full border border-white/10 bg-black/20 px-2.5 py-0.5">{meta.mime}</span>}
              {meta?.size_bytes != null && <span className="rounded-full border border-white/10 bg-black/20 px-2.5 py-0.5">{formatBytes(Number(meta.size_bytes))}</span>}
              {(meta?.link || artifactId) && <span className="max-w-full truncate rounded-full border border-white/10 bg-black/20 px-2.5 py-0.5 font-mono">{meta?.link || `artifact://${artifactId}`}</span>}
            </div>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              data-debug-id="artifact-viewer-annotate-toggle"
              disabled={!annotationSupported}
              onClick={() => setAnnotationMode((current) => !current)}
              className={`rounded-xl px-3 py-2 text-sm ${annotationSupported ? (annotationMode ? 'bg-emerald-400 text-black hover:bg-emerald-300' : 'bg-white/10 text-zinc-200 hover:bg-white/15') : 'cursor-not-allowed bg-white/5 text-zinc-500'}`}
              title={annotationSupported ? 'Toggle annotation mode' : 'Annotations are only available for Markdown/text and PNG artifacts'}
            >
              {annotationModeLabel(previewKind, annotationMode)}
            </button>
            <button
              type="button"
              data-debug-id="artifact-viewer-annotations-panel"
              onClick={() => setAnnotationsOpen((current) => !current)}
              className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15"
            >
              {annotationsOpen ? 'Hide' : 'Annotations'} ({annotations.length})
            </button>
            <button
              type="button"
              data-debug-id="artifact-viewer-copy-all-annotations-btn"
              disabled={!annotations.length}
              onClick={handleCopyAll}
              className={`rounded-xl px-3 py-2 text-sm ${annotations.length ? 'bg-white/10 text-zinc-200 hover:bg-white/15' : 'cursor-not-allowed bg-white/5 text-zinc-500'}`}
            >
              {copyAllState === 'copied' ? 'Copied all' : copyAllState === 'error' ? 'Copy failed' : 'Copy all'}
            </button>
            <a data-debug-id="artifact-viewer-download-btn" href={contentUrl} download={meta?.name || artifactId} className="rounded-xl bg-sky-400 px-3 py-2 text-sm font-semibold text-black hover:bg-sky-300">Download</a>
            <button type="button" data-debug-id="artifact-viewer-close-btn" onClick={onClose} className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15">Close</button>
          </div>
        </div>
        <div className="overflow-auto p-5">
          <div className={`grid gap-4 ${annotationsOpen ? 'xl:grid-cols-[minmax(0,1fr)_22rem]' : ''}`}>
            <div className="space-y-4">
              {loading && <div className="text-sm text-zinc-400">Loading artifact…</div>}
              {!loading && error && <div className="rounded-xl border border-amber-400/20 bg-amber-400/10 px-4 py-3 text-sm text-amber-100">{error}</div>}
              {!loading && (
                <div className="rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm text-zinc-300">
                  {supportedAnnotationHint(previewKind, annotationMode)}
                  {!annotationSupported ? ' Existing saved annotations can still be copied, edited, or removed below if present.' : ''}
                </div>
              )}
              {!loading && !error && meta && (
                <div className="space-y-4">
                  {meta.description && <div className="text-sm text-zinc-300">{meta.description}</div>}
                  {previewKind === 'markdown' && annotationMode ? (
                    <div className="rounded-2xl border border-emerald-400/20 bg-emerald-400/10 p-4">
                      <div className="text-xs font-medium uppercase tracking-wide text-emerald-200">Text annotation capture</div>
                      <div data-debug-id="artifact-viewer-text-selection-summary" className="mt-2 text-sm text-zinc-100 whitespace-pre-wrap">
                        {summarizePendingTextAnnotation(pendingTextSelection)}
                      </div>
                      <textarea
                        data-debug-id="artifact-viewer-add-annotation-comment-input"
                        value={newAnnotationComment}
                        onChange={(event) => setNewAnnotationComment(event.target.value)}
                        rows={3}
                        placeholder="What feedback should this selection capture?"
                        className="mt-3 w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-emerald-300"
                      />
                      {textAnnotationError ? (
                        <div className="mt-2 text-sm text-amber-100">{textAnnotationError}</div>
                      ) : null}
                      <div className="mt-3 flex flex-wrap gap-2">
                        <button
                          type="button"
                          data-debug-id="artifact-viewer-add-annotation-btn"
                          onClick={handleAddTextAnnotation}
                          className="rounded-xl bg-emerald-300 px-3 py-2 text-sm font-semibold text-black hover:bg-emerald-200"
                        >
                          Add annotation
                        </button>
                        <button
                          type="button"
                          data-debug-id="artifact-viewer-clear-text-selection-btn"
                          onClick={() => {
                            setPendingTextSelection(null);
                            setTextAnnotationError('');
                            window.getSelection?.()?.removeAllRanges();
                          }}
                          className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15"
                        >
                          Clear selection
                        </button>
                      </div>
                    </div>
                  ) : null}
                  {previewKind === 'png' && annotationMode ? (
                    <div data-debug-id="artifact-viewer-png-annotation-panel" className="rounded-2xl border border-emerald-400/20 bg-emerald-400/10 p-4">
                      <div className="text-xs font-medium uppercase tracking-wide text-emerald-200">Image annotation capture</div>
                      {pendingImageRegion ? (
                        <>
                          <div data-debug-id="artifact-viewer-png-region-summary" className="mt-2 text-sm text-zinc-100">
                            Region x={pendingImageRegion.xPercent.toFixed(1)}% y={pendingImageRegion.yPercent.toFixed(1)}% w={pendingImageRegion.wPercent.toFixed(1)}% h={pendingImageRegion.hPercent.toFixed(1)}%
                            {pendingImageNatural.width > 0 && pendingImageNatural.height > 0
                              ? ` · ${Math.round((pendingImageRegion.wPercent / 100) * pendingImageNatural.width)}×${Math.round((pendingImageRegion.hPercent / 100) * pendingImageNatural.height)} px`
                              : ''}
                          </div>
                          <textarea
                            data-debug-id="artifact-viewer-image-annotation-comment-input"
                            value={imageAnnotationComment}
                            onChange={(event) => setImageAnnotationComment(event.target.value)}
                            rows={3}
                            placeholder="What feedback should this region capture?"
                            className="mt-3 w-full resize-y rounded-xl border border-white/10 bg-black/30 px-3 py-2 text-sm text-zinc-100 outline-none focus:border-emerald-300"
                          />
                          <div className="mt-3 flex flex-wrap gap-2">
                            <button
                              type="button"
                              data-debug-id="artifact-viewer-add-image-annotation-btn"
                              disabled={!imageAnnotationComment.trim()}
                              onClick={handleAddImageAnnotation}
                              className={`rounded-xl px-3 py-2 text-sm font-semibold ${imageAnnotationComment.trim() ? 'bg-emerald-300 text-black hover:bg-emerald-200' : 'cursor-not-allowed bg-white/5 text-zinc-500'}`}
                            >
                              Add annotation
                            </button>
                            <button
                              type="button"
                              data-debug-id="artifact-viewer-clear-image-region-btn"
                              onClick={() => { setPendingImageRegion(null); setImageAnnotationComment(''); }}
                              className="rounded-xl bg-white/10 px-3 py-2 text-sm text-zinc-200 hover:bg-white/15"
                            >
                              Clear region
                            </button>
                          </div>
                        </>
                      ) : (
                        <div data-debug-id="artifact-viewer-png-region-empty" className="mt-2 text-sm text-zinc-300">
                          Drag on the image below to draw a bounding box, then add a comment for that region.
                        </div>
                      )}
                    </div>
                  ) : null}
                  {previewKind === 'png' ? (
                    <RegionAnnotationLayer
                      contentUrl={contentUrl}
                      alt={meta.name || artifactId}
                      annotationMode={annotationMode}
                      annotations={annotations}
                      onCreateRegion={handleCreateImageRegion}
                    />
                  ) : previewKind === 'markdown' ? (
                    loadingText
                      ? <div className="text-sm text-zinc-400">Loading preview…</div>
                      : <MarkdownBody data-debug-id="artifact-viewer-markdown-preview" source={textContent} className="text-zinc-200" onArtifactClick={setNestedArtifactId} onTextSelectionChange={annotationMode ? handleTextSelectionChange : undefined} />
                  ) : (
                    <div data-debug-id="artifact-viewer-unsupported-preview" className="rounded-xl border border-white/10 bg-black/20 px-4 py-3 text-sm text-zinc-400">
                      Preview is not available for this artifact type{meta.kind ? ` (${meta.kind}${meta.mime ? `, ${meta.mime}` : ''})` : ''}. Use Download to open it externally.
                    </div>
                  )}
                </div>
              )}
            </div>
            {annotationsOpen ? (
              <aside className="space-y-3 xl:sticky xl:top-0 xl:self-start">
                {!annotationSupported ? (
                  <div data-debug-id="artifact-viewer-annotation-unavailable" className="rounded-2xl border border-white/10 bg-black/20 px-4 py-3 text-sm text-zinc-300">
                    Annotation is unavailable for this artifact type. Annotations are available for Markdown/text and PNG artifacts only.
                  </div>
                ) : null}
                {!annotations.length ? (
                  <div data-debug-id="artifact-viewer-annotations-empty" className="rounded-2xl border border-dashed border-white/10 bg-black/20 px-4 py-5 text-sm text-zinc-400">
                    No annotations saved for this artifact yet. Turn on Annotate and use the artifact preview to create one in the capture-specific flows.
                  </div>
                ) : null}
                {annotations.map((annotation) => (
                  <AnnotationListItem
                    key={annotation.annotationId}
                    annotation={annotation}
                    onRemove={handleRemoveAnnotation}
                    onSaveComment={handleSaveComment}
                  />
                ))}
              </aside>
            ) : null}
          </div>
        </div>
      </div>
      {nestedArtifactId ? (
        <ArtifactViewer artifactId={nestedArtifactId} daemonUrl={daemonUrl} clientToken={clientToken} onClose={() => setNestedArtifactId('')} />
      ) : null}
    </div>
  );
}
