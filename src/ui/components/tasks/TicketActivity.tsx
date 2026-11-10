// origin/main's ticket Activity (REQ-T7) behind a props seam: the caller
// supplies each feed (comments, events, handoffs and, optionally, reviews) as
// data and loads it when its tab first opens (onOpen), so a Bridge-owned chain
// feeds owner-local reads instead of the Hub task events, facets and comments.

import React, { useEffect, useState } from 'react';
import { Alert, Badge, StatusPill, Tab, Tabs, TabsList, Text, type Tone } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { DecryptedMarkdown, VaultText } from '../vault/VaultText';
import type { TaskNames } from './taskNames';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import { diffAcceptance, formatAgo, type RequirementRevisionEntry } from './ticketModel';
import { EditedText } from './EditedText';

export type ActivityTab = 'all' | 'comments' | 'requirements' | 'handoffs' | 'reviews' | 'raw';

/** One feed: `items` null while it has not been read yet. */
export interface TicketFeed<T> {
  items: T[] | null;
  /** A re-read is running (the previous items stay shown). */
  loading?: boolean;
  error?: string;
  /** Older entries were left out. */
  more?: boolean;
  /** The read stopped at its bound: newer entries may be missing. */
  truncated?: boolean;
}

export interface TicketCommentItem { id: string; author: string; body: string; at: string }

/** One event, already described ("commented", "took the lease"). */
export interface TicketEventItem {
  id: string;
  kind: string;
  /** user / agent / coordinator / hub / system. */
  actorKind: string;
  actorId: string;
  text: string;
  tsMs: number;
  /** The event as read, for Raw events. */
  raw: unknown;
}

export interface TicketHandoffItem {
  id: string;
  label: string;
  tone: Tone;
  actorKind: string;
  actorId: string;
  tsMs: number;
  summary: string;
  nextSteps: string;
  waitingOn: string;
  head: string;
  requirementsRevision: string;
}

export interface TicketReviewItem {
  id: string;
  verdict: string;
  actorKind: string;
  actorId: string;
  role: string;
  attempt: string;
  tsMs: number;
  summary: string;
  /** Carried over from the Hub at migration. */
  archived: boolean;
}

export interface TicketActivityFeeds {
  comments: TicketFeed<TicketCommentItem>;
  events: TicketFeed<TicketEventItem>;
  handoffs: TicketFeed<TicketHandoffItem>;
  /** Present: a Reviews tab lists every review with its findings. */
  reviews?: TicketFeed<TicketReviewItem>;
  /** The requirement history is being read / could not be read. */
  requirementsLoading?: boolean;
  requirementsError?: string;
  /** A tab opened for the first time: read its feed. */
  onOpen?: (tab: ActivityTab) => void;
}

export interface TicketActivityProps {
  task: TaskWire;
  names: TaskNames;
  now: number;
  /** Parsed requirement history (gap G1); null when it did not parse or is not read yet. */
  history: RequirementRevisionEntry[] | null;
  rawHistory: string;
  tab: ActivityTab;
  onTabChange: (tab: ActivityTab) => void;
  feeds: TicketActivityFeeds;
  /** The comment composer, shown at the top of the feed on desktop. */
  composer?: React.ReactNode;
}

/**
 * The ticket's Activity (REQ-T7): All, Comments, Requirement changes, Handoffs
 * and Raw events (and Reviews when supplied), newest first. Each feed is asked
 * for the first time its tab opens (REQ-L1 lazy sections).
 */
export const TicketActivity: React.FC<TicketActivityProps> = ({ task, names, now, history, rawHistory, tab, onTabChange, feeds, composer }) => {
  const [opened, setOpened] = useState<Partial<Record<ActivityTab, boolean>>>({});
  useEffect(() => {
    if (opened[tab]) return;
    setOpened((o) => ({ ...o, [tab]: true }));
    feeds.onOpen?.(tab);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab]);
  const commentCount = feeds.comments.items?.length ?? Number(task.comment_summary?.count || 0);
  const changes = history || [];

  return (
    <section aria-label="Activity" data-debug-id="ticket-activity" className="flex flex-col gap-3">
      <Text as="h3" role="title" className="text-primary">Activity</Text>
      <Tabs value={tab} onChange={(v) => onTabChange(v as ActivityTab)} variant="underline">
        <TabsList label="Activity feeds" className="overflow-x-auto">
          <Tab value="all" data-debug-id="ticket-activity-tab-all">All</Tab>
          <Tab value="comments" data-debug-id="ticket-activity-tab-comments">Comments {commentCount ? <span className="tabular-nums text-faint">{commentCount}</span> : null}</Tab>
          <Tab value="requirements" data-debug-id="ticket-activity-tab-requirements">Requirement changes {changes.length ? <span className="tabular-nums text-faint">{changes.length}</span> : null}</Tab>
          <Tab value="handoffs" data-debug-id="ticket-activity-tab-handoffs">Handoffs</Tab>
          {feeds.reviews && (
            <Tab value="reviews" data-debug-id="ticket-activity-tab-reviews">Reviews {feeds.reviews.items?.length ? <span className="tabular-nums text-faint">{feeds.reviews.items.length}</span> : null}</Tab>
          )}
          <Tab value="raw" data-debug-id="ticket-activity-tab-raw">Raw events</Tab>
        </TabsList>
      </Tabs>
      {composer}
      {tab === 'comments' && <CommentFeed feed={feeds.comments} now={now} />}
      {tab === 'requirements' && (
        feeds.requirementsError ? <Text role="caption" tone="danger" data-debug-id="task-requirements-history-error">{feeds.requirementsError}</Text>
          : history === null && (feeds.requirementsLoading || !rawHistory) ? <Text role="caption" tone="faint" aria-live="polite">Loading requirement changes…</Text>
          : <RequirementChanges history={history} rawHistory={rawHistory} names={names} now={now} truncated={Boolean(task.requirements?.history_truncated)} />
      )}
      {(tab === 'all' || tab === 'raw') && <EventFeed feed={feeds.events} names={names} now={now} mode={tab} />}
      {tab === 'handoffs' && <HandoffFeed feed={feeds.handoffs} names={names} now={now} />}
      {tab === 'reviews' && feeds.reviews && <ReviewFeed feed={feeds.reviews} names={names} now={now} />}
    </section>
  );
};

function actorLabel(names: TaskNames, kind: string, id: string): string {
  if (kind === 'user') return 'You';
  if (kind === 'hub' || kind === 'system') return 'Hub';
  return (id && (names.participant(id) || names.instance(id))) || (kind === 'coordinator' ? 'Coordinator' : 'An agent');
}

/** The feed's loading / error / empty states; null once there is something to list. */
function feedState<T>(feed: TicketFeed<T>, what: string, empty: string): React.ReactNode {
  if (feed.error && !feed.items?.length) return <Text role="caption" tone="danger">{feed.error}</Text>;
  if (feed.items === null) return <Text role="caption" tone="faint" aria-live="polite">Loading {what}…</Text>;
  if (!feed.items.length && !feed.loading) return <Text role="caption" tone="faint">{empty}</Text>;
  return null;
}

function FeedFooter<T>({ feed, debugId }: { feed: TicketFeed<T>; debugId: string }) {
  return (
    <>
      {feed.loading && feed.items !== null && <Text role="caption" tone="faint" aria-live="polite" data-debug-id={`${debugId}-loading`}>Loading…</Text>}
      {feed.error && Boolean(feed.items?.length) && <Text role="caption" tone="danger">{feed.error}</Text>}
      {feed.truncated && (
        <div data-debug-id={`${debugId}-truncated`}>
          <Alert tone="warning">The history is longer than this view reads; newer entries may be missing.</Alert>
        </div>
      )}
      {feed.more && <Text role="caption" tone="faint" data-debug-id={`${debugId}-more`}>Showing the most recent only.</Text>}
    </>
  );
}

function CommentFeed({ feed, now }: { feed: TicketFeed<TicketCommentItem>; now: number }) {
  return (
    <div className="flex flex-col gap-3" data-debug-id="ticket-activity-feed-comments">
      {feedState(feed, 'comments', 'No comments yet.')}
      {Boolean(feed.items?.length) && (
        <ol className="flex flex-col gap-3">
          {feed.items!.map((c) => (
            <li key={c.id} data-debug-id={`ticket-comment-${c.id}`} className="flex gap-3">
              <TicketAgentAvatar name={c.author} state="idle" />
              <span className="min-w-0 flex-1">
                <span className="flex flex-wrap items-baseline gap-x-2 text-body-sm">
                  <span className="font-semibold text-primary">{c.author}</span>
                  {c.at && <time dateTime={c.at} className="text-caption text-faint">{formatAgo(c.at, now)}</time>}
                </span>
                <span className="mt-0.5 block text-body-sm text-primary">
                  <DecryptedMarkdown source={c.body} compact copyAll={false} />
                </span>
              </span>
            </li>
          ))}
        </ol>
      )}
      <FeedFooter feed={feed} debugId="ticket-comments" />
    </div>
  );
}

/** Requirement revisions, newest first, each with its reason and diff. */
function RequirementChanges({ history, rawHistory, names, now, truncated }: { history: RequirementRevisionEntry[] | null; rawHistory: string; names: TaskNames; now: number; truncated: boolean }) {
  if (history === null) {
    // G1 fallback: the text did not parse, so show it as the hub wrote it.
    return (
      <pre data-debug-id="task-requirements-history" className="max-h-96 overflow-auto whitespace-pre-wrap rounded-md bg-canvas p-3 font-mono text-code-sm text-muted">
        <VaultText value={rawHistory} />
      </pre>
    );
  }
  if (!history.length) return <Text role="caption" tone="faint" data-debug-id="task-requirements-history-empty">The requirements have not changed since the ticket was created.</Text>;
  return (
    <ol data-debug-id="task-requirements-history" className="flex flex-col gap-4">
      {history.map((h) => {
        const diff = diffAcceptance(h.before.acceptance, h.after.acceptance);
        const who = actorLabel(names, h.actorKind, h.actorId);
        return (
          <li key={`${h.revision}-${h.eventId ?? ''}`} data-debug-id={`ticket-requirement-change-${h.revision}`} className="flex flex-col gap-1.5 border-l-2 border-subtle pl-3">
            <span className="flex flex-wrap items-center gap-1.5 text-caption text-muted">
              <Badge tone="neutral">Rev {h.revision}</Badge>
              <span className="font-semibold text-primary">{who}</span> changed requirements
              <span className="text-faint">{formatAgo(h.tsMs, now)}</span>
            </span>
            {h.reason && (
              <blockquote className="border-l-2 border-strong pl-3 text-body-sm text-primary">
                <VaultText value={h.reason} />
              </blockquote>
            )}
            <ul className="flex flex-col gap-1 text-caption">
              {h.before.goal !== h.after.goal && (
                <li className="flex gap-2">
                  <Badge tone="info">Goal</Badge>
                  <span className="min-w-0 break-words">
                    <span className="block text-faint line-through"><VaultText value={h.before.goal} /></span>
                    <span className="text-primary"><VaultText value={h.after.goal} /></span>
                  </span>
                </li>
              )}
              {diff.items.filter((i) => i.tag).map((i, n) => (
                <li key={`i${n}`} className="flex gap-2">
                  <Badge tone={i.tag === 'new' ? 'success' : 'info'}>{i.tag === 'new' ? 'Add' : 'Edit'}</Badge>
                  <span className="min-w-0 break-words text-primary"><EditedText previous={i.previous} text={i.text} /></span>
                </li>
              ))}
              {diff.removed.map((r, n) => (
                <li key={`r${n}`} className="flex gap-2">
                  <Badge tone="danger">Remove</Badge>
                  <span className="min-w-0 break-words text-faint line-through"><VaultText value={r} /></span>
                </li>
              ))}
            </ul>
          </li>
        );
      })}
      {truncated && <Text role="caption" tone="faint">Showing recent changes. Older changes remain in the ticket history.</Text>}
    </ol>
  );
}

/** Every event, newest first. */
function EventFeed({ feed, names, now, mode }: { feed: TicketFeed<TicketEventItem>; names: TaskNames; now: number; mode: 'all' | 'raw' }) {
  return (
    <div className="flex flex-col gap-3">
      {feedState(feed, 'activity', 'Nothing has happened yet.')}
      {Boolean(feed.items?.length) && (
        <ol data-debug-id={`ticket-activity-feed-${mode}`} className="flex flex-col gap-3">
          {feed.items!.map((e) => (mode === 'raw' ? <RawEvent key={e.id} event={e} /> : <EventRow key={e.id} event={e} names={names} now={now} />))}
        </ol>
      )}
      <FeedFooter feed={feed} debugId="ticket-events" />
    </div>
  );
}

/** Memoized by the event alone: the clock tick never re-serializes it. */
const RawEvent = React.memo(function RawEvent({ event }: { event: TicketEventItem }) {
  return (
    <li data-debug-id="task-timeline-event">
      <pre className="max-h-48 overflow-auto rounded-md bg-canvas p-2 font-mono text-code-sm text-muted">{JSON.stringify(event.raw, null, 2)}</pre>
    </li>
  );
});

const EventRow = React.memo(function EventRow({ event: e, names, now }: { event: TicketEventItem; names: TaskNames; now: number }) {
  const actor = actorLabel(names, e.actorKind, e.actorId);
  return (
    <li data-debug-id="task-timeline-event" className="flex gap-3">
      <TicketAgentAvatar name={actor} state="idle" />
      <span className="min-w-0 flex-1">
        <span className="block text-body-sm text-primary">
          <span className="font-semibold">{actor}</span> <span className="text-muted">{e.text}</span>
        </span>
        <span className="block text-caption text-faint">{e.tsMs ? formatAgo(e.tsMs, now) : ''}</span>
      </span>
    </li>
  );
});

/** What each agent said when it handed the ticket back, newest first. */
function HandoffFeed({ feed, names, now }: { feed: TicketFeed<TicketHandoffItem>; names: TaskNames; now: number }) {
  return (
    <div className="flex flex-col gap-3" data-debug-id="ticket-activity-feed-handoffs">
      {feedState(feed, 'handoffs', 'No handoffs yet.')}
      {Boolean(feed.items?.length) && (
        <ol className="flex flex-col gap-3">
          {feed.items!.map((h) => {
            const actor = actorLabel(names, h.actorKind, h.actorId);
            return (
              <li key={h.id} data-debug-id={`ticket-handoff-${h.id}`} className="flex gap-3">
                <TicketAgentAvatar name={actor} state="idle" />
                <span className="flex min-w-0 flex-1 flex-col gap-1">
                  <span className="flex flex-wrap items-center gap-1.5 text-body-sm">
                    <span className="font-semibold text-primary">{actor}</span>
                    <StatusPill tone={h.tone}>{h.label}</StatusPill>
                    {h.requirementsRevision && <span className="text-caption text-faint">rev {h.requirementsRevision}</span>}
                    {h.head && <Text as="code" role="code-sm">{h.head.slice(0, 12)}</Text>}
                  </span>
                  {h.summary && (
                    <span className="block border-l-2 border-strong pl-3 text-body-sm text-primary">
                      <DecryptedMarkdown source={h.summary} compact copyAll={false} />
                    </span>
                  )}
                  {h.waitingOn && <Text as="span" role="caption" tone="muted">Waiting on {h.waitingOn}</Text>}
                  {h.nextSteps && (
                    <span className="flex flex-col gap-0.5">
                      <Text as="span" role="overline" tone="faint">Next steps</Text>
                      <DecryptedMarkdown source={h.nextSteps} compact copyAll={false} />
                    </span>
                  )}
                  <span className="text-caption text-faint">{h.tsMs ? formatAgo(h.tsMs, now) : ''}</span>
                </span>
              </li>
            );
          })}
        </ol>
      )}
      <FeedFooter feed={feed} debugId="ticket-handoffs" />
    </div>
  );
}

/** Every review with its verdict and findings, newest first. */
function ReviewFeed({ feed, names, now }: { feed: TicketFeed<TicketReviewItem>; names: TaskNames; now: number }) {
  return (
    <div className="flex flex-col gap-3" data-debug-id="ticket-activity-feed-reviews">
      {feedState(feed, 'reviews', 'No reviews yet.')}
      {Boolean(feed.items?.length) && (
        <ol className="flex flex-col gap-3">
          {feed.items!.map((r) => {
            const actor = actorLabel(names, r.actorKind, r.actorId);
            return (
              <li key={r.id} data-debug-id={`ticket-review-${r.id}`} className="flex gap-3">
                <TicketAgentAvatar name={actor} state="idle" />
                <span className="flex min-w-0 flex-1 flex-col gap-1">
                  <span className="flex flex-wrap items-center gap-1.5 text-body-sm">
                    <span className="font-semibold text-primary">{actor}</span>
                    {r.role && <span className="text-caption text-muted">({r.role})</span>}
                    <StatusPill tone={r.verdict === 'approve' ? 'success' : 'danger'}>{r.verdict === 'approve' ? 'Approved' : 'Changes requested'}</StatusPill>
                    {r.attempt && <span className="text-caption text-faint">attempt {r.attempt}</span>}
                    {r.archived && <Badge tone="neutral">Archived from Hub</Badge>}
                  </span>
                  {r.summary && (
                    <span className="block border-l-2 border-strong pl-3 text-body-sm text-primary">
                      <DecryptedMarkdown source={r.summary} compact copyAll={false} />
                    </span>
                  )}
                  <span className="text-caption text-faint">{r.tsMs ? formatAgo(r.tsMs, now) : ''}</span>
                </span>
              </li>
            );
          })}
        </ol>
      )}
      <FeedFooter feed={feed} debugId="ticket-reviews" />
    </div>
  );
}

export default TicketActivity;
