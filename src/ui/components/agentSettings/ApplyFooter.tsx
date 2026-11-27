/**
 * ApplyFooter — the Agent settings panel's sticky staged-changes footer
 * (`agent-panel-apply`, see DESIGN.md "Staged changes and Apply"). Pure render of
 * `applyFooterView` (useApplyAgentSettings.ts): one chip per change, the restart
 * note, alerts (hub error, 409 "Changed since you opened"), and the buttons:
 * Discard (ghost) + the gold primary ("Apply and restart" | "Restart after this
 * turn" + ghost "Restart now" | "Apply and start" | "Retry change"), or the queued
 * state ("Waiting for the turn to finish…" + Cancel, later "Still waiting" +
 * Restart now). Touch: Discard takes 1 part and the primary 2, every control 44px.
 */
import React, { useEffect, useId, useRef } from 'react';
import { Alert, Button, Text } from '@ui';
import type { ApplyFooterView } from './useApplyAgentSettings';

export interface ApplyFooterProps {
  view: ApplyFooterView;
  touch?: boolean;
  onApply: () => void;
  onRestartNow: () => void;
  onCancel: () => void;
  onDiscard: () => void;
}

function Chip({ label, from, to }: { label: string; from: string; to: string }) {
  return (
    <li
      data-debug-id="agent-panel-apply-chip"
      className="inline-flex max-w-full items-center gap-1.5 rounded-[var(--radius-sm)] border border-subtle bg-surface-raised px-2.5 py-1 text-[length:var(--text-label-size)] text-primary"
    >
      <span className="shrink-0 text-muted">{label}</span>
      <code className="truncate font-mono text-code-sm">{from}</code>
      <span aria-hidden="true" className="shrink-0 text-muted">→</span>
      <span className="sr-only">to</span>
      <code className="truncate font-mono text-code-sm">{to}</code>
    </li>
  );
}

export function ApplyFooter({ view, touch = false, onApply, onRestartNow, onCancel, onDiscard }: ApplyFooterProps) {
  const statusRef = useRef<HTMLParagraphElement>(null);
  const blockedId = useId();
  const hasPrimary = Boolean(view.primary);
  const hadPrimary = useRef(hasPrimary);
  // Apply/Restart now unmount the button that had focus (the footer switches to its
  // status line): hand focus to the status line instead of letting it fall to <body>.
  useEffect(() => {
    const was = hadPrimary.current;
    hadPrimary.current = hasPrimary;
    if (!was || hasPrimary || !statusRef.current) return;
    const active = document.activeElement;
    if (!active || active === document.body) statusRef.current.focus();
  }, [hasPrimary]);
  if (!view.visible) return null;
  const control = touch ? 'min-h-11' : '';
  const reason = view.blocked || '';
  return (
    <div
      data-debug-id="agent-panel-apply"
      role="region"
      aria-label="Staged changes"
      className="flex flex-col gap-3 border-t border-subtle bg-surface px-4 py-3"
    >
      {view.chips.length ? (
        <ul aria-label="Changes" className="flex flex-wrap gap-1.5">
          {view.chips.map((c) => <Chip key={c.field} label={c.label} from={c.from} to={c.to} />)}
        </ul>
      ) : null}
      {view.note ? (
        <Text as="p" role="body-sm" tone="muted" data-debug-id="agent-panel-apply-note">{view.note}</Text>
      ) : null}
      {view.error ? (
        <Alert tone="danger" data-debug-id="agent-panel-apply-error">{view.error}</Alert>
      ) : null}
      {view.conflict ? (
        <Alert tone="warning" role="alert" data-debug-id="agent-panel-apply-conflict">{view.conflict}</Alert>
      ) : null}
      {reason ? (
        <Text as="p" role="body-sm" tone="muted" id={blockedId} data-debug-id="agent-panel-apply-blocked">{reason}</Text>
      ) : null}
      {view.issues.length ? (
        <ul data-debug-id="agent-panel-destination-validation" className="list-disc space-y-1 pl-5 text-caption text-danger">
          {view.issues.map((issue) => <li key={issue}>{issue}</li>)}
        </ul>
      ) : null}
      {/* Always mounted while the footer is, so a change of its text is announced
          (a live region that appears together with its text usually is not). */}
      <p
        ref={statusRef}
        role="status"
        aria-live="polite"
        tabIndex={-1}
        data-debug-id="agent-panel-apply-status"
        className={view.status ? 'text-[length:var(--text-body-sm-size)] text-primary outline-none' : 'sr-only'}
      >
        {view.status}
      </p>
      {view.cancel || (view.restartNow && !view.primary) ? (
        <div className="flex flex-wrap justify-end gap-2">
          {view.restartNow && !view.primary ? (
            <Button variant="ghost" className={control} data-debug-id="agent-panel-apply-restart-now"
              disabled={view.restartNow.disabled} onClick={onRestartNow}>
              Restart now
            </Button>
          ) : null}
          {view.cancel ? (
            <Button variant="ghost" className={control} data-debug-id="agent-panel-apply-cancel"
              aria-label="Cancel restart" disabled={view.cancel.disabled} onClick={onCancel}>
              Cancel
            </Button>
          ) : null}
        </div>
      ) : null}
      {view.primary ? (
        <div className={touch ? 'grid grid-cols-3 gap-2' : 'flex flex-wrap items-center justify-end gap-2'}>
          {view.restartNow ? (
            <Button variant="ghost" className={touch ? `${control} col-span-3` : ''} data-debug-id="agent-panel-apply-restart-now"
              disabled={view.restartNow.disabled} onClick={onRestartNow}>
              Restart now
            </Button>
          ) : null}
          {view.discard ? (
            <Button variant="ghost" className={touch ? `${control} col-span-1` : ''} data-debug-id="agent-panel-apply-discard"
              disabled={view.discard.disabled} onClick={onDiscard}>
              Discard
            </Button>
          ) : null}
          <Button
            variant="primary"
            className={touch ? `${control} ${view.discard ? 'col-span-2' : 'col-span-3'}` : ''}
            data-debug-id="agent-panel-apply-btn"
            data-apply-kind={view.primary.kind}
            aria-describedby={reason ? blockedId : undefined}
            disabled={view.primary.disabled}
            loading={view.primary.loading}
            onClick={onApply}
          >
            {view.primary.label}
          </Button>
        </div>
      ) : null}
    </div>
  );
}

export default ApplyFooter;
