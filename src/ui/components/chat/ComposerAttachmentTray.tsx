import type { PendingAttachment } from './useComposerAttachments';

export function ComposerAttachmentTray({ attachments, isMobile, disabled = false, debugPrefix = 'conversation', debugIds, onRetry, onRemove }: {
  attachments: PendingAttachment[];
  isMobile: boolean;
  disabled?: boolean;
  debugPrefix?: string;
  debugIds?: { tray: string; retry: string; remove: string };
  onRetry: (attachment: PendingAttachment) => void;
  onRemove: (localId: string) => void;
}) {
  const hasUploadingAttachments = attachments.some(a => a.status === 'uploading');
  const hasFailedAttachments = attachments.some(a => a.status === 'error');
  return attachments.length > 0 ? (
    <div
      data-debug-id={debugIds?.tray ?? `${debugPrefix}-attachment-tray`}
      className="mb-2 space-y-2 rounded-2xl border border-subtle bg-surface-raised p-2 text-xs text-primary"
    >
      {attachments.map((a) => (
        <div
          key={a.localId}
          data-debug-id={`${debugPrefix}-attachment-${a.localId}`}
          className="rounded-xl border border-subtle bg-surface px-2.5 py-2"
        >
          <div className="flex min-w-0 items-center gap-2">
            <span
              className={
                a.status === 'uploaded'
                  ? 'text-success'
                  : a.status === 'error'
                  ? 'text-danger'
                  : 'text-accent'
              }
            >
              {a.status === 'uploading'
                ? '⇧'
                : a.status === 'uploaded'
                ? '✓'
                : '!'}
            </span>
            <span className="min-w-0 flex-1 truncate" title={a.name}>
              {a.name}
            </span>
            <span
              className={
                a.status === 'uploaded'
                  ? 'text-success'
                  : a.status === 'error'
                  ? 'text-danger'
                  : 'text-accent'
              }
            >
              {a.status === 'uploading'
                ? 'Uploading…'
                : a.status === 'uploaded'
                ? 'Uploaded'
                : 'Failed'}
            </span>
            {a.status === 'error' ? (
              <button
                type="button"
                data-debug-id={`${debugIds?.retry ?? `${debugPrefix}-attachment-retry`}-${a.localId}`}
                onClick={() => onRetry(a)}
                className={`rounded-full border border-subtle text-primary hover:bg-neutral-soft ${isMobile ? 'min-h-11 px-4' : 'px-2 py-0.5'}`}
              >
                Retry
              </button>
            ) : null}
            <button
              type="button"
              data-debug-id={`${debugIds?.remove ?? `${debugPrefix}-attachment-remove`}-${a.localId}`}
              disabled={disabled}
              onClick={() => onRemove(a.localId)}
              className={`rounded-full border border-subtle text-muted hover:bg-neutral-soft hover:text-primary ${isMobile ? 'min-h-11 px-4' : 'px-2 py-0.5'}`}
            >
              Remove
            </button>
          </div>
          {a.status === 'uploading' ? (
            <div
              data-debug-id={`${debugPrefix}-attachment-progress-${a.localId}`}
              className="mt-2 h-1.5 overflow-hidden rounded-full bg-neutral-soft"
            >
              <div className="h-full w-1/2 animate-pulse rounded-full bg-accent" />
            </div>
          ) : null}
          {a.error ? (
            <div
              data-debug-id={`${debugPrefix}-attachment-error-${a.localId}`}
              className="mt-1 text-danger"
            >
              {a.error}
            </div>
          ) : null}
        </div>
      ))}
      {hasUploadingAttachments ? (
        <div
          data-debug-id={`${debugPrefix}-attachment-uploading-hint`}
          className="text-caption text-muted"
        >
          You can keep typing. Send unlocks when uploads finish.
        </div>
      ) : null}
      {hasFailedAttachments ? (
        <div
          data-debug-id={`${debugPrefix}-attachment-failed-hint`}
          className="text-caption text-danger"
        >
          Retry or remove failed uploads before sending.
        </div>
      ) : null}
    </div>
  ) : null;
}
