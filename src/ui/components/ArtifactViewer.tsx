import { useEffect, useMemo, useRef, useState } from 'react';
import { IconButton, Spinner } from '@ui';
import {
  useArtifactContentState,
  useFetchArtifactMetaQuery,
  useFetchArtifactTextContentQuery,
} from '../api/endpoints/artifacts';
import { openArtifactPage } from '../utils/artifactPage';
import { copyTextToClipboard } from '../utils/artifactAnnotations';
import MarkdownBody from './MarkdownBody';
import HtmlBundlePreview from './HtmlBundlePreview';
import { HTML_BUNDLE_KIND } from '../utils/htmlBundle';
import { VaultText } from './vault/VaultText';
import { isVaultArmored } from '../utils/vaultContent';
import { audioMimeForArtifact, isAudioArtifact } from '../utils/audioArtifact';
import { AudioPlayer } from './chat/AudioPlayer';
import { audioContentStatus, useAudioBlobUrl } from './ArtifactAudioPreview';

type ArtifactViewerProps = {
  artifactId: string;
  daemonUrl: string;
  clientToken: string;
  onClose?: () => void;
  embedded?: boolean;
  onOpenArtifact?: (artifactId: string) => void;
};

type ArtifactMeta = {
  name: string;
  kind: string;
  mime: string;
  content_type?: string;
  contentType?: string;
  ext: string;
  link: string;
  renderer?: string;
};

type PreviewKind = 'html-bundle' | 'markdown' | 'text' | 'json' | 'diff' | 'image' | 'audio' | 'unsupported';
type CopyState = 'idle' | 'copied' | 'error';

// UI-10: kind-aware rendering. text/markdown -> rendered markdown; json ->
// pretty-printed; diff -> monospace diff; images (including PNG) -> ZoomableImage;
// audio/voice (REQ-VOICE-3) -> the inline AudioPlayer.
function classifyPreview(meta: ArtifactMeta | null): PreviewKind {
  if (!meta) return 'unsupported';
  const kind = String(meta.kind || '').toLowerCase();
  const mime = String(meta.mime || meta.content_type || meta.contentType || '').toLowerCase();
  const rawExt = String(meta.ext || '').toLowerCase();
  const name = String(meta.name || '').toLowerCase();
  const nameDot = name.lastIndexOf('.');
  const ext = rawExt
    ? (rawExt.startsWith('.') ? rawExt : `.${rawExt}`)
    : (nameDot >= 0 ? name.slice(nameDot) : '');
  const renderer = String(meta.renderer || '').toLowerCase();
  // REQ-BUNDLE-3: only the explicit kind; a generic ZIP stays a downloadable file.
  if (kind === HTML_BUNDLE_KIND) {
    return 'html-bundle';
  }
  if (kind === 'diff' || ext === '.diff' || ext === '.patch' || mime === 'text/x-diff') {
    return 'diff';
  }
  if (kind === 'json' || mime === 'application/json' || mime === 'text/json' || ext === '.json') {
    return 'json';
  }
  if (renderer === 'markdown' || kind === 'markdown' || kind === 'text' || mime === 'text/markdown' || mime === 'text/plain' || ext === '.md' || ext === '.markdown' || ext === '.txt' || name.endsWith('.md') || name.endsWith('.markdown') || name.endsWith('.txt')) {
    return 'markdown';
  }
  if (kind === 'png' || kind === 'image' || kind === 'jpeg' || kind === 'jpg'
      || mime === 'image/png' || mime === 'image/jpeg' || mime === 'image/jpg'
      || ext === '.png' || ext === '.jpg' || ext === '.jpeg'
      || kind === 'gif' || mime === 'image/gif' || ext === '.gif'
      || kind === 'webp' || mime === 'image/webp' || ext === '.webp'
      || mime.startsWith('image/')) {
    return 'image';
  }
  if (isAudioArtifact(meta)) {
    return 'audio';
  }
  if (mime.startsWith('text/')) {
    return 'text';
  }
  return 'unsupported';
}

// UI-10: image view with wheel/drag zoom on desktop and pinch-zoom/pan on touch.
// Renders all images (including PNG) with transform-based zoom and pan.
function ZoomableImage({ contentUrl, alt }: { contentUrl: string; alt: string }) {
  const [scale, setScale] = useState(1);
  const [tx, setTx] = useState(0);
  const [ty, setTy] = useState(0);
  const dragRef = useRef<{ x: number; y: number; tx: number; ty: number } | null>(null);
  const pinchRef = useRef<{ distance: number; scale: number } | null>(null);

  function clampScale(next: number) {
    return Math.min(8, Math.max(1, next));
  }

  function handleWheel(event: React.WheelEvent<HTMLDivElement>) {
    if (!event.ctrlKey && Math.abs(event.deltaY) < 30) return; // trackpad two-finger = scroll
    event.preventDefault();
    const delta = -event.deltaY * 0.0025;
    setScale((current) => clampScale(current * (1 + delta)));
  }

  function handlePointerDown(event: React.PointerEvent<HTMLDivElement>) {
    if (event.pointerType === 'touch' && event.isPrimary === false) return;
    (event.currentTarget as HTMLDivElement).setPointerCapture?.(event.pointerId);
    dragRef.current = { x: event.clientX, y: event.clientY, tx, ty };
  }

  function handlePointerMove(event: React.PointerEvent<HTMLDivElement>) {
    if (!dragRef.current) return;
    const dx = event.clientX - dragRef.current.x;
    const dy = event.clientY - dragRef.current.y;
    setTx(dragRef.current.tx + dx);
    setTy(dragRef.current.ty + dy);
  }

  function handlePointerUp() {
    dragRef.current = null;
  }

  function handleTouchStart(event: React.TouchEvent<HTMLDivElement>) {
    if (event.touches.length === 2) {
      const a = event.touches[0];
      const b = event.touches[1];
      const distance = Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY);
      pinchRef.current = { distance, scale };
      dragRef.current = null;
    }
  }

  function handleTouchMove(event: React.TouchEvent<HTMLDivElement>) {
    if (event.touches.length === 2 && pinchRef.current) {
      event.preventDefault();
      const a = event.touches[0];
      const b = event.touches[1];
      const distance = Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY);
      const ratio = distance / (pinchRef.current.distance || distance);
      setScale(clampScale(pinchRef.current.scale * ratio));
    }
  }

  function handleTouchEnd(event: React.TouchEvent<HTMLDivElement>) {
    if (event.touches.length < 2) pinchRef.current = null;
  }

  function reset() {
    setScale(1);
    setTx(0);
    setTy(0);
  }

  return (
    <div
      data-debug-id="artifact-viewer-zoomable-image"
      className="relative flex touch-none select-none items-center justify-center overflow-hidden"
      // REQ-MODAL-2: a MIN-height is the opposite direction from the caps and still belongs on
      // the visible region. Against the layout viewport this floor stayed 325px however short
      // the visible region got, so it forced the capped panel to overflow and scroll with the
      // keyboard up. Tracking the visible region means the floor shrinks with it instead.
      style={{ minHeight: 'calc(var(--app-viewport-height) * 0.4)' }}
      onDoubleClick={reset}
      onWheel={handleWheel}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerUp}
      onTouchStart={handleTouchStart}
      onTouchMove={handleTouchMove}
      onTouchEnd={handleTouchEnd}
    >
      <img
        data-debug-id="artifact-viewer-image-preview"
        src={contentUrl}
        alt={alt}
        draggable={false}
        className="max-h-[calc(var(--app-viewport-height)*0.7)] max-w-full select-none"
        style={{ transform: `translate(${tx}px, ${ty}px) scale(${scale})`, transformOrigin: 'center center', transition: dragRef.current ? 'none' : 'transform 0.08s ease-out' }}
      />
    </div>
  );
}

// UI-10: json/diff/text rendered with monospace. json is pretty-printed; diff
// keeps +/- markers. Self-contained content fetch.
function ArtifactCodePreview({ artifactId, kind, daemonUrl, clientToken }: { artifactId: string; kind: 'json' | 'diff' | 'text'; daemonUrl: string; clientToken: string }) {
  const textQuery = useFetchArtifactTextContentQuery({ artifactId, versionNo: null, daemonUrl, clientToken }, { skip: !artifactId || !clientToken });
  const raw = textQuery.data?.text || '';
  const display = useMemo(() => {
    if (kind !== 'json') return raw;
    try {
      return JSON.stringify(JSON.parse(raw), null, 2);
    } catch {
      return raw;
    }
  }, [raw, kind]);

  if (textQuery.isFetching) return <div className="text-sm text-muted">Loading preview…</div>;
  if (textQuery.error) return <div className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">Failed to load artifact content.</div>;
  if (isVaultArmored(raw)) {
    return (
      <div className="rounded-xl border border-subtle bg-surface-raised p-6 text-center">
        <VaultText value={raw} />
      </div>
    );
  }
  return (
    <pre data-debug-id={`artifact-viewer-${kind}-body`} className="overflow-auto p-4 text-[12.5px] leading-5 text-primary">
      <code>{display || '(empty)'}</code>
    </pre>
  );
}

export default function ArtifactViewer({ artifactId, daemonUrl, clientToken, onClose, embedded = false, onOpenArtifact }: ArtifactViewerProps) {
  const artifactRequestAuth = { daemonUrl, clientToken };
  const metaQuery = useFetchArtifactMetaQuery({ artifactId, ...artifactRequestAuth }, { skip: !artifactId || !clientToken });
  const meta = (metaQuery.currentData?.artifact || null) as ArtifactMeta | null;

  const [copyLinkState, setCopyLinkState] = useState<CopyState>('idle');
  const copyFeedbackTimer = useRef<number | undefined>(undefined);

  useEffect(() => {
    setCopyLinkState('idle');
    return () => window.clearTimeout(copyFeedbackTimer.current);
  }, [artifactId]);

  useEffect(() => {
    if (embedded || !onClose) return;
    function handleEscape(event: KeyboardEvent) {
      if (event.key === 'Escape' && !event.defaultPrevented) onClose?.();
    }
    window.addEventListener('keydown', handleEscape);
    return () => window.removeEventListener('keydown', handleEscape);
  }, [embedded, onClose]);

  const previewKind = classifyPreview(meta);
  const contentState = useArtifactContentState({ daemonUrl, clientToken, artifactId });
  const contentUrl = contentState.url;
  const previewNeedsContent = previewKind === 'image' || previewKind === 'html-bundle' || previewKind === 'audio';
  const audioUrl = useAudioBlobUrl(previewKind === 'audio' && !contentState.locked ? contentState.blob : null, audioMimeForArtifact(meta));
  const textQuery = useFetchArtifactTextContentQuery(
    { artifactId, versionNo: null, ...artifactRequestAuth },
    { skip: !artifactId || !clientToken || previewKind !== 'markdown' },
  );
  const textContent = textQuery.currentData?.text || '';
  const loading = metaQuery.isFetching;
  const loadingText = textQuery.isFetching;
  const loadingContent = previewNeedsContent && contentState.loading;
  const contentError = previewNeedsContent ? contentState.error : '';
  const error = metaQuery.error
    ? 'Failed to load artifact metadata.'
    : textQuery.error
      ? 'Failed to load artifact content.'
      : (!loading && !meta ? 'Artifact metadata is unavailable.' : '');
  const title = meta?.name || artifactId;
  const canDownload = Boolean(contentUrl && !contentState.loading && !(previewKind === 'html-bundle' && contentState.locked));

  async function handleCopyLink() {
    try {
      await copyTextToClipboard(meta?.link || `artifact://${artifactId}`);
      setCopyLinkState('copied');
    } catch {
      setCopyLinkState('error');
    }
    window.clearTimeout(copyFeedbackTimer.current);
    copyFeedbackTimer.current = window.setTimeout(() => setCopyLinkState('idle'), 1500);
  }

  function handleDownload() {
    if (!canDownload) return;
    const anchor = document.createElement('a');
    anchor.href = contentUrl;
    const downloadName = meta?.name || artifactId;
    // The html-bundle payload is the decrypted ZIP, byte-identical to what was uploaded.
    anchor.download = previewKind === 'html-bundle' && !downloadName.toLowerCase().endsWith('.zip') ? `${downloadName}.zip` : downloadName;
    document.body.appendChild(anchor);
    anchor.click();
    document.body.removeChild(anchor);
  }

  return (
    <div data-debug-id={embedded ? 'artifact-viewer-embedded-shell' : 'artifact-viewer-page-shell'} className="flex h-full min-h-0 w-full flex-col bg-canvas">
      <div data-debug-id="artifact-viewer" className="flex h-full min-h-0 w-full flex-col overflow-hidden">
        {!embedded && (
          <header
            data-debug-id="artifact-viewer-header"
            className="relative z-10 flex min-h-14 shrink-0 items-center gap-2 bg-canvas/90 px-3 py-2 shadow-sm backdrop-blur-md sm:min-h-12 sm:gap-3 sm:px-4"
          >
            <div
              aria-hidden="true"
              className="pointer-events-none absolute inset-x-0 -bottom-6 h-6 bg-gradient-to-b from-canvas/90 via-canvas/50 to-transparent backdrop-blur-sm"
            />
            <IconButton data-debug-id="artifact-viewer-back-btn" icon="arrow-left" label="Back" onClick={onClose} />
            <h1 className="min-w-0 flex-1 truncate text-base font-semibold text-primary" title={isVaultArmored(title) ? undefined : title}>
              <VaultText value={title} fallback={artifactId} />
            </h1>
            <IconButton
              data-debug-id="artifact-viewer-copy-link-btn"
              icon={copyLinkState === 'copied' ? 'check' : 'copy'}
              label={copyLinkState === 'copied' ? 'Link copied' : copyLinkState === 'error' ? 'Copy failed. Retry copying artifact link' : 'Copy artifact link'}
              className={copyLinkState === 'error' ? 'text-warning' : undefined}
              onClick={handleCopyLink}
            />
            <IconButton
              data-debug-id="artifact-viewer-download-btn"
              icon="download"
              label="Download artifact"
              disabled={!canDownload}
              onClick={handleDownload}
            />
          </header>
        )}
        <div data-debug-id="artifact-viewer-content" className="min-h-0 flex-1 overflow-auto">
          {loading && <Spinner size="lg" label="Loading artifact" className="m-4" />}
          {!loading && error && <div className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">{error}</div>}
          {!loading && !error && meta && (
            loadingContent ? (
              <div data-debug-id="artifact-viewer-content-loading" className="grid min-h-[calc(var(--app-viewport-height)*0.4)] place-items-center">
                <Spinner size="lg" label="Loading artifact content" />
              </div>
            ) : contentError ? (
              <div data-debug-id="artifact-viewer-content-error" className="rounded-xl border border-warning/30 bg-warning-soft px-4 py-3 text-sm text-warning">{contentError}</div>
            ) : previewKind === 'html-bundle' ? (
              <HtmlBundlePreview blob={contentState.blob} locked={contentState.locked} lockReason={contentState.lockReason} />
            ) : previewKind === 'image' ? (
              <ZoomableImage contentUrl={contentUrl} alt={meta.name || artifactId} />
            ) : previewKind === 'audio' ? (
              <div data-debug-id="artifact-viewer-audio" className="rounded-xl border border-subtle bg-surface-raised px-4 py-3">
                <AudioPlayer src={audioUrl} debugId="artifact-viewer-audio-player" label="Audio" />
                {!audioUrl ? <div data-debug-id="artifact-viewer-audio-status" className="mt-2 text-sm text-muted">{audioContentStatus(contentState)}</div> : null}
              </div>
            ) : previewKind === 'markdown' ? (
              loadingText ? (
                <div className="text-sm text-muted">Loading preview…</div>
              ) : isVaultArmored(textContent) ? (
                <div className="rounded-xl border border-subtle bg-surface-raised p-6 text-center">
                  <VaultText value={textContent} />
                </div>
              ) : (
                <MarkdownBody
                  data-debug-id="artifact-viewer-markdown-preview"
                  source={textContent}
                  className="p-4 text-primary"
                  onArtifactClick={onOpenArtifact ?? openArtifactPage}
                />
              )
            ) : previewKind === 'json' || previewKind === 'diff' || previewKind === 'text' ? (
              <ArtifactCodePreview artifactId={artifactId} kind={previewKind} {...artifactRequestAuth} />
            ) : (
              <div data-debug-id="artifact-viewer-unsupported-preview" className="rounded-xl border border-subtle bg-surface-raised px-4 py-3 text-sm text-muted">
                Preview is not available for this artifact type{meta.kind ? ` (${meta.kind}${meta.mime || meta.content_type || meta.contentType ? `, ${meta.mime || meta.content_type || meta.contentType}` : ''})` : ''}.
              </div>
            )
          )}
        </div>
      </div>
    </div>
  );
}
