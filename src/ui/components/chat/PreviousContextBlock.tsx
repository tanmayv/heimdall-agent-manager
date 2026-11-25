import React, { useId, useState } from 'react';
import { Icon } from '@ui';

/**
 * previous_context messages (T5/T6 context rollover): the handoff an agent
 * wrote for its own restarted session. The hub stores it inbound
 * (user_to_agent), but it is agent-authored reference material, so the
 * transcript shows it as a full-width block that stays collapsed until opened.
 */
export const PREVIOUS_CONTEXT_MESSAGE_TYPE = 'previous_context';

export function isPreviousContextMessage(message: { messageType?: string; message_type?: string }): boolean {
  return String(message.messageType || message.message_type || '') === PREVIOUS_CONTEXT_MESSAGE_TYPE;
}

function finiteNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null;
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** 200000 -> "200K", 1000000 -> "1M", 475000 -> "475K", 1500000 -> "1.5M". */
export function formatContextWindow(tokens: number): string {
  if (tokens >= 1_000_000) return `${trimDecimal(tokens / 1_000_000)}M`;
  if (tokens >= 1_000) return `${trimDecimal(tokens / 1_000)}K`;
  return String(Math.round(tokens));
}

function trimDecimal(value: number): string {
  return String(Math.round(value * 10) / 10);
}

/**
 * Summary label. Rollover % (`context_pct`, 0-100) and window
 * (`context_window`, or `window`, in tokens) are optional; whatever is
 * missing is left out rather than guessed.
 */
export function previousContextLabel(metadata: any): string {
  const meta = metadata && typeof metadata === 'object' ? metadata : {};
  const pct = finiteNumber(meta.context_pct ?? meta.rollover_pct);
  const windowTokens = finiteNumber(meta.context_window ?? meta.window);
  const pctText = pct !== null ? `${Math.round(pct)}%` : '';
  const windowText = windowTokens !== null ? formatContextWindow(windowTokens) : '';
  if (pctText && windowText) return `Previous context (rollover at ${pctText} of ${windowText})`;
  if (pctText) return `Previous context (rollover at ${pctText})`;
  if (windowText) return `Previous context (${windowText} window)`;
  return 'Previous context';
}

/** Collapsed by default, with a native button for Enter/Space activation. */
export function PreviousContextBlock({
  messageId,
  metadata,
  children,
}: {
  messageId: string;
  metadata?: any;
  children: React.ReactNode;
}) {
  const [expanded, setExpanded] = useState(false);
  const bodyId = useId();
  return (
    <div
      data-debug-id={`conversation-previous-context-${messageId}`}
      className="my-2 min-w-0 text-sm text-muted"
    >
      <button
        type="button"
        aria-expanded={expanded}
        aria-controls={bodyId}
        onClick={() => setExpanded((open) => !open)}
        data-debug-id={`conversation-previous-context-toggle-${messageId}`}
        className="inline-flex max-w-full cursor-pointer items-center gap-1 rounded-sm text-left font-normal focus-visible:shadow-focus"
      >
        <span className="truncate">{previousContextLabel(metadata)}</span>
        <Icon name="chevron-right" size={12} className={`motion-safe:transition-transform${expanded ? ' rotate-90' : ''}`} />
      </button>
      <div
        id={bodyId}
        hidden={!expanded}
        data-debug-id={`conversation-previous-context-body-${messageId}`}
        className="mt-1 [&_.conversation-markdown]:text-muted"
      >
        {children}
      </div>
    </div>
  );
}
