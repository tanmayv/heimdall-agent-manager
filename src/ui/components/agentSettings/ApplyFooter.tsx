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
import React from 'react';
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
      className="inline-flex max-w-full items-center gap-1.5 rounded-full border border-subtle bg-surface-raised px-2.5 py-1 text-[length:var(--text-label-size)] text-primary"
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
        <Text as="p" role="body-sm" tone="muted" data-debug-id="agent-panel-apply-blocked">{reason}</Text>
      ) : null}
      {view.issues.length ? (
        <ul data-debug-id="agent-panel-destination-validation" className="list-disc space-y-1 pl-5 text-caption text-danger">
          {view.issues.map((issue) => <li key={issue}>{issue}</li>)}
        </ul>
      ) : null}
      {view.status ? (
        <Text as="p" role="body-sm" className="text-primary" aria-live="polite" data-debug-id="agent-panel-apply-status">
          {view.status}
        </Text>
      ) : null}
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
              disabled={view.cancel.disabled} onClick={onCancel}>
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
