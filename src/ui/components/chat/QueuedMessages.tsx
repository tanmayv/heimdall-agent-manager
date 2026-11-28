import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { Button, Icon } from '@ui';
import type { ChatMessage } from './types';
import { sendNowErrorText, type TrayView, type UnreadTrayState } from './acpDelivery';

/**
 * ACP user messages the agent has not received yet, above the composer and outside the
 * transcript (docs/acp-send-now.md). Visual reference: prototype task_18eab8eba93619f2
 * (1e008829). Each is a normal user bubble on the LEFT, its text lined up with the
 * composer text (the origin of the send animation), without a timestamp. A small
 * "After this turn" label carries the ONE batch action (Send now / Sending… / Retry) for
 * the turn-held messages; messages that are not turn-held only say "Sending". A message
 * leaves this area when the agent gets it or reads it, and the transcript plays the send
 * animation from its bubble (see AgentChatPane).
 */

/** ChatMessageList's user-bubble look: radius, border, surface, padding, font. */
const USER_BUBBLE_CLASS = 'min-w-0 max-w-full overflow-hidden break-words [overflow-wrap:anywhere] rounded-[15px] border border-subtle bg-surface-raised px-[14px] py-[10px] text-sm text-primary';
const BUBBLE_WIDTH_CLASS = 'flex min-w-0 max-w-[86%] flex-col items-start sm:max-w-[78%]';
/** Long messages are clipped to a few lines here (full text in the tooltip). */
const CLAMP_PX = 132;
const CLAMP_FADE = 'linear-gradient(to bottom, #000 calc(100% - 1.75rem), transparent)';
const QUIET_ACTION = 'shrink-0 !px-1.5 !py-0.5 text-[11px] max-sm:-my-2 max-sm:min-h-11';

type Tone = 'queued' | 'sending' | 'failed';

function plainTitle(body: string): string {
  return body.length > 600 ? `${body.slice(0, 600)}…` : body;
}

function QueuedBubble({ message, tone, title, renderBody, bubbleRef }: {
  message: ChatMessage;
  tone: Tone;
  title: string;
  renderBody: (message: ChatMessage) => ReactNode;
  bubbleRef: (key: string, el: HTMLElement | null) => void;
}) {
  const bodyRef = useRef<HTMLDivElement>(null);
  const [clipped, setClipped] = useState(false);
  useLayoutEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    const measure = () => setClipped(el.scrollHeight > CLAMP_PX + 1);
    measure();
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(measure);
    observer?.observe(el);
    return () => observer?.disconnect();
  }, [message.body]);
  const toneClass = tone === 'sending' ? 'opacity-60'
    : tone === 'failed' ? '[border-color:color-mix(in_srgb,var(--color-danger)_50%,transparent)] opacity-70'
    : 'opacity-85';
  return (
    <li data-debug-id={`conversation-queued-item-${message.messageId}`} data-queued-item={message.key} data-queued-tone={tone}
      className="flex min-w-0 max-w-full justify-start motion-safe:animate-[reply-rise-in_200ms_ease-out_both]">
      <div className={BUBBLE_WIDTH_CLASS}>
        <div ref={(el) => bubbleRef(message.key, el)} data-queued-bubble=""
          title={clipped ? `${plainTitle(message.body)}\n\n${title}` : title}
          className={`${USER_BUBBLE_CLASS} transition-opacity duration-200 ${toneClass}`}>
          <div ref={bodyRef} className="overflow-hidden"
            style={clipped ? { maxHeight: CLAMP_PX, maskImage: CLAMP_FADE, WebkitMaskImage: CLAMP_FADE } : { maxHeight: CLAMP_PX }}>
            {renderBody(message)}
          </div>
        </div>
      </div>
    </li>
  );
}

/** Small label lined up with the bubble text, with at most one quiet action beside it. */
function GroupLabel({ children, action, tone = 'faint', title, debugId }: {
  children: ReactNode; action?: ReactNode; tone?: 'faint' | 'danger'; title?: string; debugId?: string;
}) {
  return (
    <li role="presentation" className="flex min-h-7 items-center justify-start gap-1 pl-[15px]">
      <span data-debug-id={debugId} title={title}
        className={`inline-flex min-w-0 items-center gap-1 truncate text-[11px] font-medium leading-4 ${tone === 'danger' ? 'text-danger' : 'text-faint'}`}>
        {children}
      </span>
      {action}
    </li>
  );
}

const count = (n: number) => `${n} ${n === 1 ? 'message' : 'messages'}`;

export function QueuedMessages({
  view, tooltip, localError, onSendNow, onRetry, renderBody, bubbleRef,
}: {
  view: TrayView<ChatMessage>;
  tooltip: string;
  /** A Send now request the Hub refused outright (stale epoch, not ACP, network). */
  localError: string;
  onSendNow: (messageIds: string[]) => void;
  onRetry: () => void;
  renderBody: (message: ChatMessage) => ReactNode;
  bubbleRef: (key: string, el: HTMLElement | null) => void;
}) {
  const { sending, batch, waiting, batchPhase, batchError } = view;
  const listRef = useRef<HTMLOListElement>(null);
  const lastKey = (waiting[waiting.length - 1] ?? sending[sending.length - 1])?.key ?? '';
  // Like the transcript, keep the newest message in view when one is added.
  useLayoutEffect(() => {
    const list = listRef.current;
    if (list && lastKey) list.scrollTop = list.scrollHeight;
  }, [lastKey]);
  const total = sending.length + batch.length + waiting.length;
  if (!total) return null;

  const pending = batchPhase === 'pending';
  const failed = batchPhase === 'failed';
  const sendLabel = `Send ${waiting.length === 1 ? 'the waiting message' : `all ${waiting.length} waiting messages`} now`;
  const sendNowButton = (
    <Button size="sm" variant="ghost" data-debug-id="conversation-queued-send-now"
      aria-label={sendLabel} title={tooltip} className={`${QUIET_ACTION} text-accent`}
      onClick={() => onSendNow(waiting.map((m) => m.messageId))}>
      Send now
    </Button>
  );

  // Full wording for assistive tech; the visible labels stay short.
  const parts: string[] = [];
  if (sending.length) parts.push(`Sending ${count(sending.length)}.`);
  if (pending) parts.push(`Sending ${count(batch.length || waiting.length)} now.`);
  else if (failed) parts.push(`${sendNowErrorText(batchError)} ${count(batch.length)} not sent yet.`);
  else if (localError) parts.push(localError);
  if (!pending && !failed && waiting.length) parts.push(`${count(waiting.length)} will be sent after this turn.`);
  if ((pending || failed) && batch.length && waiting.length) parts.push(`${count(waiting.length)} arrived later and wait for their own Send now.`);
  const announcement = parts.join(' ');

  let queuedLead: ReactNode = null;
  if (pending) {
    queuedLead = (
      <GroupLabel debugId="conversation-queued-title" action={
        <Button size="sm" variant="ghost" data-debug-id="conversation-queued-send-now" loading
          aria-label={`Sending ${count(batch.length || waiting.length)} now`} className={`${QUIET_ACTION} text-muted`}>
          Sending…
        </Button>
      }>After this turn</GroupLabel>
    );
  } else if (failed) {
    queuedLead = (
      <GroupLabel debugId="conversation-queued-title" tone="danger" title={sendNowErrorText(batchError)} action={
        <Button size="sm" variant="ghost" data-debug-id="conversation-queued-retry"
          aria-label={`Retry sending ${count(batch.length)} now`} title={tooltip}
          className={`${QUIET_ACTION} text-danger`} leading={<Icon name="refresh" size={12} />} onClick={onRetry}>
          Retry
        </Button>
      }><Icon name="alert" size={12} className="shrink-0" />Not sent yet</GroupLabel>
    );
  } else if (waiting.length) {
    queuedLead = (
      <GroupLabel debugId="conversation-queued-title" tone={localError ? 'danger' : 'faint'}
        title={localError || tooltip} action={sendNowButton}>
        {localError ? <><Icon name="alert" size={12} className="shrink-0" />Not sent yet</> : 'After this turn'}
      </GroupLabel>
    );
  }
  const batchTone: Tone = pending ? 'sending' : failed ? 'failed' : 'queued';

  return (
    <section data-debug-id="conversation-queued" aria-label="Messages not yet received by the agent" className="mb-2">
      <span data-debug-id="conversation-queued-status" role="status" aria-live="polite" className="sr-only">{announcement}</span>
      <ol ref={listRef} data-debug-id="conversation-queued-list"
        className="chat-scrollbar flex max-h-[32dvh] min-w-0 flex-col gap-1.5 overflow-y-auto overflow-x-hidden overscroll-contain pl-[6px] pr-1">
        {sending.length ? <GroupLabel debugId="conversation-queued-sending-title"
          title="Saved, not yet received by the agent">Sending</GroupLabel> : null}
        {sending.map((m) => <QueuedBubble key={m.key} message={m} tone="sending" title="Sending" renderBody={renderBody} bubbleRef={bubbleRef} />)}
        {queuedLead}
        {batch.map((m) => <QueuedBubble key={m.key} message={m} tone={batchTone} title={pending ? 'Sending now' : 'Not sent yet'} renderBody={renderBody} bubbleRef={bubbleRef} />)}
        {(pending || failed) && batch.length > 0 && waiting.length > 0 ? (
          <GroupLabel debugId="conversation-queued-later" title="Arrived after Send now: waits for its own Send now">
            Arrived later
          </GroupLabel>
        ) : null}
        {waiting.map((m) => <QueuedBubble key={m.key} message={m} tone="queued" title="Queued: sent after this turn" renderBody={renderBody} bubbleRef={bubbleRef} />)}
      </ol>
    </section>
  );
}

/**
 * Send now for a runtime without members (GET send-now `send_now: "notice"`, PTY). The
 * agent reads its own conversation, so unread messages stay in the transcript and this
 * one action asks the agent to read them now (the current turn stops first). `state`
 * (unreadTrayState): `waiting` while an unread message is after the last typed notice, so
 * the bridge waits for the current turn and Send now is offered; `notified` once the
 * notice covered all of them, when the same action is offered as Interrupt (it stops the
 * turn so the agent reads now); `pending` keeps today's "N not read yet" with Send now
 * (an older hub, or an agent that is not running).
 */
export function UnreadSendNow({ unread, state, phase, error, tooltip, localError, onSendNow, onRetry }: {
  unread: number;
  state: UnreadTrayState;
  phase: 'idle' | 'pending' | 'failed';
  error: string;
  tooltip: string;
  localError: string;
  onSendNow: () => void;
  onRetry: () => void;
}) {
  if (!unread) return null;
  const allNotified = state === 'notified';
  const label = allNotified ? 'Agent notified, not read yet'
    : state === 'waiting' ? 'Waiting for the current turn' : `${count(unread)} not read yet`;
  const spoken = allNotified ? `Agent notified, ${count(unread)} not read yet`
    : state === 'waiting' ? `${count(unread)} waiting for the current turn` : label;
  let action: ReactNode;
  let announcement = `${spoken}.`;
  if (phase === 'pending') {
    announcement = `Asking the agent to read ${count(unread)} now.`;
    action = (
      <Button size="sm" variant="ghost" data-debug-id="conversation-queued-send-now" loading
        aria-label={announcement} className={`${QUIET_ACTION} text-muted`}>
        Sending…
      </Button>
    );
  } else if (phase === 'failed') {
    announcement = `${sendNowErrorText(error)} ${spoken}.`;
    action = (
      <Button size="sm" variant="ghost" data-debug-id="conversation-queued-retry"
        aria-label={`Retry asking the agent to read ${count(unread)} now`} title={tooltip}
        className={`${QUIET_ACTION} text-danger`} leading={<Icon name="refresh" size={12} />} onClick={onRetry}>
        Retry
      </Button>
    );
  } else if (allNotified && !localError) {
    action = (
      <Button size="sm" variant="ghost" data-debug-id="conversation-queued-interrupt"
        aria-label={INTERRUPT_HINT} title={INTERRUPT_HINT} className={`${QUIET_ACTION} text-accent`} onClick={onSendNow}>
        Interrupt
      </Button>
    );
  } else {
    if (localError) announcement = `${localError} ${spoken}.`;
    action = (
      <Button size="sm" variant="ghost" data-debug-id="conversation-queued-send-now"
        aria-label={`Have the agent read ${unread === 1 ? 'the unread message' : `all ${unread} unread messages`} now`}
        title={tooltip} className={`${QUIET_ACTION} text-accent`} onClick={onSendNow}>
        Send now
      </Button>
    );
  }
  const failed = phase === 'failed' || (phase === 'idle' && Boolean(localError));
  return (
    <section data-debug-id="conversation-unread" data-unread-state={state}
      aria-label="Messages the agent has not read yet" className="mb-2">
      <span data-debug-id="conversation-queued-status" role="status" aria-live="polite" className="sr-only">{announcement}</span>
      <ol className="flex min-w-0 flex-col pl-[6px] pr-1">
        <GroupLabel debugId="conversation-queued-title" tone={failed ? 'danger' : 'faint'}
          title={phase === 'failed' ? sendNowErrorText(error) : localError || spoken} action={action}>
          {failed ? <><Icon name="alert" size={12} className="shrink-0" />Not sent yet</> : label}
        </GroupLabel>
      </ol>
    </section>
  );
}

const INTERRUPT_HINT = "Interrupt the agent's current turn so it reads now";
