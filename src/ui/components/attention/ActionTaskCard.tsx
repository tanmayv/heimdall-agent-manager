import type { ReactNode } from 'react';
import { Icon } from '@ui';
import type { AttentionTaskItem } from '../../api/endpoints/attention';
import { DecryptedMarkdown, VaultText } from '../vault';
import { formatAge } from './attentionModel';
import { StartAgentFailure } from './StartAgentAction';
import { isBlockedItem, needLabel } from './actionTrayModel';

/**
 * One task waiting on the user in the chat pane's action tray (REQ-AT-2/4).
 * Top to bottom: title; agent · age; what is needed; the ask (dominant, scrolls
 * inside the card); then `footer` (the action row or an inline picker).
 *
 * A blocked card's ask is the agent's question (the card excerpt); a review
 * card shows the excerpt of the worker's result.
 */
export function ActionTaskCard({ item, mobile, now, footer }: { item: AttentionTaskItem; mobile: boolean; active?: boolean; now: number; footer: ReactNode }) {
  const blocked = isBlockedItem(item);
  const agent = item.details.assignee_name || item.context.agent_name || 'Agent';
  const age = formatAge(item.attention_since, now);
  return (
    <article
      data-debug-id={`action-tray-card-${blocked ? 'blocked' : 'review'}`}
      aria-label={blocked ? 'Ticket blocked on you' : 'Ticket waiting on your review'}
      className="flex h-full min-h-0 min-w-0 flex-col gap-3"
    >
      <header className="min-w-0 space-y-1">
        <h3 data-debug-id="action-tray-card-title" className={`font-semibold leading-snug text-primary ${mobile ? 'text-[16px]' : 'text-[17px]'}`}>
          <VaultText value={item.title} fallback="Untitled ticket" />
        </h3>
        <div className="flex min-w-0 items-center gap-2 text-[13px] text-muted">
          <span aria-hidden="true" className="grid h-5 w-5 shrink-0 place-items-center rounded-full bg-neutral-soft text-muted">
            <Icon name="bot" size={12} />
          </span>
          <span data-debug-id="action-tray-card-agent" className="min-w-0 truncate">
            <span className="font-medium text-primary">{agent}</span>
            {age ? ` · ${age === 'just now' ? age : `${age} ago`}` : ''}
          </span>
        </div>
        <p data-debug-id="action-tray-card-need" className={`pt-1 text-[12px] font-semibold uppercase tracking-wide ${blocked ? 'text-warning' : 'text-info'}`}>
          {needLabel(item)}
        </p>
      </header>
      {/* touch-pan-y: its own vertical scroller; horizontal gestures page the tray. */}
      <div data-debug-id="action-tray-card-ask" className="min-h-0 flex-1 touch-pan-y overflow-y-auto overscroll-contain pr-1">
        {blocked ? <BlockedAsk item={item} mobile={mobile} /> : <ReviewResult item={item} mobile={mobile} />}
      </div>
      <div className="shrink-0">{footer}</div>
    </article>
  );
}

function askClass(mobile: boolean): string {
  return `text-primary ${mobile ? 'text-[18px] leading-[1.45]' : 'text-[19px] leading-[1.5]'}`;
}

function BlockedAsk({ item, mobile }: { item: AttentionTaskItem; mobile: boolean }) {
  const excerpt = item.details.excerpt;
  if (item.details.badge === 'agent_not_running') return <StartAgentFailure item={item} />;
  if (!excerpt?.body) {
    return (
      <p data-debug-id="action-tray-card-no-ask" className="text-[15px] text-muted">
        The agent is waiting on you but did not say what it needs. Open the ticket to see its latest comments.
      </p>
    );
  }
  return <DecryptedMarkdown source={excerpt.body} compact copyAll={false} className={askClass(mobile)} data-debug-id="action-tray-card-question" />;
}

/**
 * A review card's result: the card excerpt. (The per-attempt facets came from
 * the Hub task routes, which are gone with the Hub task chains.)
 */
function ReviewResult({ item, mobile }: { item: AttentionTaskItem; mobile: boolean }) {
  const textSize = mobile ? 'text-[16px] leading-[1.5]' : 'text-[17px] leading-[1.55]';
  const excerpt = item.details.excerpt;
  if (excerpt?.body) return <DecryptedMarkdown source={excerpt.body} compact copyAll={false} className={textSize} data-debug-id="action-tray-review-excerpt" />;
  return <p data-debug-id="action-tray-review-empty" className="text-[15px] text-muted">The worker left no summary. Open the ticket to review it.</p>;
}
