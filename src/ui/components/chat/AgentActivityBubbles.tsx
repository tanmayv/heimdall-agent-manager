import { useCallback, useEffect, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import {
  AgentActionItem,
  selectAgentActivityBuffer,
  selectReplayableActions,
} from '../../store/agentActivitySlice';

// Push-only, ephemeral row of small "activity bubbles" rendered in a reserved,
// fixed-height gutter just above the chat composer, for the CURRENTLY-VIEWED
// instance only. Each bubble shows a short, human-readable, id-free summary of a
// ham-ctl action the agent just performed (composed hub-side in P1, buffered in
// the transient slice in P2).
//
// Animation model (polish): the gutter is ALWAYS reserved so the composer never
// shifts; bubbles sit on ONE clipped line. The FIRST bubble (empty row) shows a
// 3-dot indicator for DOTS_MS then morphs into the pill; SUBSEQUENT bubbles slide
// in from the left and expand, pushing existing bubbles over to make room. Exit
// collapses. Under prefers-reduced-motion we skip the dots and fall back to a plain
// fade (see styles.css). Lifetime is owned HERE (not redux): each bubble lives
// BUBBLE_LIFETIME_MS. On mount/open (Q2: open-conversation replay ONLY) we replay
// buffered actions <5min old, staggered at REPLAY_STAGGER_MS, "as if just arrived".

const BUBBLE_LIFETIME_MS = 4000;
const REPLAY_STAGGER_MS = 400;
// 3-dot indicator duration before the first bubble morphs into its pill.
const DOTS_MS = 200;
// Matches the CSS .agent-bubble-exit duration — how long an exiting bubble stays
// mounted so the collapse/fade can play before removal.
const EXIT_ANIM_MS = 220;
// Guard: never surface a "live" buffer entry already older than one lifetime.
const LIVE_FRESHNESS_MS = BUBBLE_LIFETIME_MS + 1000;

type BubblePhase = 'dots' | 'pill' | 'exiting';
type VisibleBubble = AgentActionItem & {
  phase: BubblePhase;
  // True once a first-bubble 'dots' entry has morphed into its pill (drives the
  // morph animation vs the plain slide-in used by subsequent bubbles).
  morphed?: boolean;
};

function prefersReducedMotion(): boolean {
  return (
    typeof window !== 'undefined' &&
    typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches
  );
}

export default function AgentActivityBubbles({ instanceId }: { instanceId: string }) {
  const buffer = useSelector((state: any) => selectAgentActivityBuffer(state, instanceId));
  const [visible, setVisible] = useState<VisibleBubble[]>([]);

  // Ids we've already surfaced (replayed or live) so the live effect never
  // double-shows a buffered item. Reset when the viewed instance changes.
  const seenIdsRef = useRef<Set<string>>(new Set());
  // All pending timers, cleared on unmount / instance switch.
  const timersRef = useRef<number[]>([]);
  // How many bubbles currently occupy the row (incl. exiting). Lets us decide, at
  // push time, whether an arriving bubble is the "first" (empty row → dots morph).
  const liveCountRef = useRef(0);

  const removeBubble = useCallback((id: string) => {
    setVisible((prev) => prev.filter((b) => b.id !== id));
    liveCountRef.current = Math.max(0, liveCountRef.current - 1);
  }, []);

  // Show one bubble now and schedule its fade-out (exiting) + removal after its
  // lifetime. Stable across renders (only touches refs/setState), so both the
  // replay and live effects share it.
  const pushVisible = useCallback((item: AgentActionItem) => {
    // "First bubble" = the row is currently empty; play the 3-dot morph, unless
    // the user prefers reduced motion (then no dots — a plain fade-in pill).
    const isFirst = liveCountRef.current === 0 && !prefersReducedMotion();
    liveCountRef.current += 1;
    const phase: BubblePhase = isFirst ? 'dots' : 'pill';
    // Prepend so the newest bubble slides in at the left and the rest slide over.
    setVisible((prev) => (prev.some((b) => b.id === item.id) ? prev : [{ ...item, phase }, ...prev]));

    let lifeDelay = 0;
    if (isFirst) {
      lifeDelay = DOTS_MS;
      const morph = window.setTimeout(() => {
        setVisible((prev) => prev.map((b) => (b.id === item.id ? { ...b, phase: 'pill', morphed: true } : b)));
      }, DOTS_MS);
      timersRef.current.push(morph);
    }
    const hide = window.setTimeout(() => {
      setVisible((prev) => prev.map((b) => (b.id === item.id ? { ...b, phase: 'exiting' } : b)));
      const remove = window.setTimeout(() => removeBubble(item.id), EXIT_ANIM_MS);
      timersRef.current.push(remove);
    }, lifeDelay + BUBBLE_LIFETIME_MS);
    timersRef.current.push(hide);
  }, [removeBubble]);

  // Fresh mount / instance switch: reset, then replay recent buffered actions
  // (<5min) staggered, "as if they just arrived". Marking them seen up front so
  // the live effect below skips the same entries already present in the buffer.
  useEffect(() => {
    const timers = timersRef.current;
    const clearAllTimers = () => {
      for (const t of timers) window.clearTimeout(t);
      timers.length = 0;
    };

    clearAllTimers();
    seenIdsRef.current = new Set();
    liveCountRef.current = 0;
    setVisible([]);

    selectReplayableActions(buffer, Date.now()).forEach((item, index) => {
      seenIdsRef.current.add(item.id);
      timers.push(window.setTimeout(() => pushVisible(item), index * REPLAY_STAGGER_MS));
    });

    return clearAllTimers;
    // Replay is intentionally keyed on the viewed instance only; the buffer
    // snapshot is read at mount. Live growth is handled by the effect below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [instanceId, pushVisible]);

  // Live append: when the buffer grows, surface genuinely new + fresh entries.
  useEffect(() => {
    const now = Date.now();
    for (const item of buffer) {
      if (seenIdsRef.current.has(item.id)) continue;
      seenIdsRef.current.add(item.id);
      if (now - Number(item.ts || 0) > LIVE_FRESHNESS_MS) continue; // stale catch-up, skip
      pushVisible(item);
    }
  }, [buffer, pushVisible]);

  // Reserved fixed-height gutter: ALWAYS rendered (even when empty) so the
  // composer never shifts as bubbles appear/disappear. Single line, clipped.
  return (
    <div
      data-debug-id="conversation-activity-bubbles"
      aria-hidden="true"
      className="pointer-events-none mb-1 flex h-6 items-center gap-1.5 overflow-hidden whitespace-nowrap px-1"
    >
      {visible.map((bubble) => {
        const animClass =
          bubble.phase === 'exiting'
            ? 'agent-bubble-exit'
            : bubble.phase === 'dots'
              ? 'agent-bubble-dots-in'
              : bubble.morphed
                ? 'agent-bubble-morph'
                : 'agent-bubble-pill-in';
        return (
          <span
            key={bubble.id}
            data-debug-id={`conversation-activity-bubble-${bubble.action || 'action'}`}
            title={bubble.summary}
            className={`inline-flex max-w-[240px] shrink-0 items-center overflow-hidden rounded-full border border-white/10 bg-white/[0.04] px-2.5 py-1 text-[11px] leading-none text-zinc-400 ${animClass}`}
          >
            {bubble.phase === 'dots' ? (
              <span data-debug-id="conversation-activity-bubble-dots" className="inline-flex items-center gap-0.5">
                <span className="agent-bubble-dot h-1 w-1 rounded-full bg-zinc-500" style={{ animationDelay: '0ms' }} />
                <span className="agent-bubble-dot h-1 w-1 rounded-full bg-zinc-500" style={{ animationDelay: '150ms' }} />
                <span className="agent-bubble-dot h-1 w-1 rounded-full bg-zinc-500" style={{ animationDelay: '300ms' }} />
              </span>
            ) : (
              <span className="truncate">{bubble.summary}</span>
            )}
          </span>
        );
      })}
    </div>
  );
}
