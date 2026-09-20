import { useEffect, useRef, useState } from 'react';
import { useGetShellPreviewTokenMutation } from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';

interface ShellPreviewPanelProps {
  session: ShellSession;
  onClose?: () => void;
}

export function ShellPreviewPanel({ session, onClose }: ShellPreviewPanelProps) {
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [loadError, setLoadError] = useState(false);
  const [getPreviewToken, tokenState] = useGetShellPreviewTokenMutation();
  const iframeRef = useRef<HTMLIFrameElement | null>(null);

  const canPreview =
    session.kind === 'server' &&
    session.server_port > 0 &&
    session.status === 'running';

  const fetchToken = async () => {
    if (!canPreview) return;
    setLoadError(false);
    try {
      const result = await getPreviewToken({ sessionId: session.session_id }).unwrap();
      setPreviewUrl(result.preview_url);
    } catch {
      setLoadError(true);
    }
  };

  useEffect(() => {
    fetchToken();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session.session_id, canPreview]);

  const handleRefresh = () => {
    setPreviewUrl(null);
    fetchToken();
  };

  const handleIframeError = () => {
    setLoadError(true);
  };

  if (!canPreview) {
    return (
      <div
        data-debug-id={`shell-preview-panel-${session.session_id}`}
        className="flex h-40 items-center justify-center rounded-xl border border-subtle bg-surface text-xs text-muted"
      >
        Preview not available ({session.kind} · {session.status}
        {session.server_port <= 0 ? ' · no port' : ''})
      </div>
    );
  }

  return (
    <div
      data-debug-id={`shell-preview-panel-${session.session_id}`}
      className="overflow-hidden rounded-xl border border-subtle bg-surface"
    >
      {/* Header */}
      <div className="flex items-center justify-between border-b border-subtle bg-surface-raised px-3 py-1.5 text-xs text-muted">
        <div className="flex items-center gap-2">
          <span className="font-semibold text-primary">Preview</span>
          {session.label && (
            <span className="text-[10px] text-faint truncate max-w-[200px]">{session.label}</span>
          )}
          {session.server_port > 0 && (
            <span className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-mono text-muted">
              :{session.server_port}
            </span>
          )}
        </div>
        <div className="flex items-center gap-1">
          <button
            type="button"
            title="Refresh preview"
            onClick={handleRefresh}
            disabled={tokenState.isLoading}
            className="rounded px-2 py-0.5 text-[10px] font-semibold text-accent hover:bg-accent/10 disabled:opacity-40"
          >
            {tokenState.isLoading ? '…' : '↻ Refresh'}
          </button>
          {onClose && (
            <button
              type="button"
              title="Close preview"
              onClick={onClose}
              className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
            >
              ×
            </button>
          )}
        </div>
      </div>

      {/* iframe */}
      <div className="relative h-[480px] w-full bg-surface">
        {tokenState.isLoading && (
          <div className="absolute inset-0 flex items-center justify-center text-xs text-muted">
            Loading preview…
          </div>
        )}

        {loadError && (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 text-xs text-muted">
            <span className="text-2xl">⚠</span>
            <span>Server not responding</span>
            <button
              type="button"
              onClick={handleRefresh}
              className="rounded bg-neutral-soft px-3 py-1 font-semibold text-primary hover:opacity-80"
            >
              Retry
            </button>
          </div>
        )}

        {previewUrl && !loadError && (
          <iframe
            ref={iframeRef}
            src={previewUrl}
            title={`Preview: ${session.label || session.session_id}`}
            onError={handleIframeError}
            className="h-full w-full border-0"
            sandbox="allow-same-origin allow-scripts allow-forms allow-popups"
          />
        )}
      </div>
    </div>
  );
}
