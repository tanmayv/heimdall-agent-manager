// A Bridge-owned ticket's handoffs: what each agent said when it handed the
// ticket back (handoff, block, switch or submit): summary, next steps, what
// it waits on and the head it submitted. Read on demand: it scans history.

import { Button, EmptyState, StatusPill, Text, type Tone } from '@ui';
import type { OwnerHandoff } from '../../api/ownerChains';
import { DecryptedMarkdown } from '../vault';
import { TicketCard } from '../tasks/TicketCard';

const KIND: Record<OwnerHandoff['kind'], { label: string; tone: Tone }> = {
  'lease.submit': { label: 'Submitted', tone: 'success' },
  'lease.handoff': { label: 'Handed off', tone: 'info' },
  'lease.block': { label: 'Blocked', tone: 'warning' },
  'lease.switch': { label: 'Switched away', tone: 'neutral' },
};

export interface OwnerHandoffsState { handoffs: OwnerHandoff[] | null; error: string; more: boolean }

export function OwnerHandoffsCard({ state, onShow, formatWhen }: { state: OwnerHandoffsState | null; onShow: () => void; formatWhen: (iso: string) => string }) {
  return (
    <TicketCard debugId="owner-chain-handoffs" title="Handoffs">
      {!state ? (
        <Button size="sm" variant="ghost" data-debug-id="owner-chain-handoffs-show" onClick={onShow}>Show handoffs</Button>
      ) : state.handoffs === null ? <Text as="p" role="caption" tone="muted" aria-live="polite">Loading handoffs…</Text>
        : state.error ? <Text as="p" role="caption" tone="danger" data-debug-id="owner-chain-handoffs-error">{state.error}</Text>
        : state.handoffs.length === 0 ? <EmptyState data-debug-id="owner-chain-no-handoffs" title="No handoffs yet" description="An agent's handoff, block or submission appears here." />
        : (
          <ol className="space-y-3">
            {state.handoffs.map((h) => (
              <li key={h.seq} data-debug-id={`owner-chain-handoff-${h.seq}`} className="space-y-1 border-l-2 border-subtle pl-3">
                <div className="flex flex-wrap items-center gap-1.5">
                  <StatusPill tone={KIND[h.kind].tone}>{KIND[h.kind].label}</StatusPill>
                  {h.actorId && <Text as="code" role="code-sm" tone="muted">{h.actorId}</Text>}
                  {h.at && <Text as="span" role="caption" tone="faint">{formatWhen(h.at)}</Text>}
                  {h.requirementsRevision && <Text as="span" role="caption" tone="faint">rev {h.requirementsRevision}</Text>}
                  {h.head && <Text as="code" role="code-sm">{h.head.slice(0, 12)}</Text>}
                </div>
                {h.summary && <DecryptedMarkdown source={h.summary} compact copyAll={false} />}
                {h.waitingOn && <Text as="p" role="caption" tone="muted">Waiting on {h.waitingOn}</Text>}
                {h.nextSteps && (
                  <div>
                    <Text as="h5" role="overline" tone="faint">Next steps</Text>
                    <DecryptedMarkdown source={h.nextSteps} compact copyAll={false} />
                  </div>
                )}
              </li>
            ))}
          </ol>
        )}
      {state?.more && <Text as="p" role="caption" tone="muted">Older handoffs are not shown.</Text>}
    </TicketCard>
  );
}

export default OwnerHandoffsCard;
