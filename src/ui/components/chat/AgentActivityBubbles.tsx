import { useCallback, useEffect, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import {
  AgentActionItem,
  selectAgentActivityBuffer,
  selectReplayableActions,
} from '../../store/agentActivitySlice';

// Push-only, ephemeral row of small "activity bubbles" rendered just above the
// chat composer for the CURRENTLY-VIEWED instance only. Each bubble shows a short,
// human-readable, id-free summary of a ham-ctl action the agent just performed
// (composed hub-side in P1, buffered in the transient slice in P2).
//
// Lifetime is owned HERE (not redux): each bubble is visible for BUBBLE_LIFETIME_MS
// then fades out. On mount/open (Q2: open-conversation replay ONLY — no
// tab-visibility) we replay the buffered actions from the last 5 minutes, staggered
// at REPLAY_STAGGER_MS "as if they just arrived"; live events append as they land.

// Per-bubble visible lifetime (user spec: each bubble lives 4s).
const BUBBLE_LIFETIME_MS = 4000;
// Stagger between replayed bubbles on open.
const REPLAY_STAGGER_MS = 400;
// Matches the CSS .agent-bubble-exit animation duration (styles.css) — how long we
// keep an exiting bubble mounted so the fade-out can play before removal.
const EXIT_ANIM_MS = 240;
// Guard: never surface a "live" buffer entry that is already older than one
// lifetime (e.g. an event that arrived while the effect was catching up).
const LIVE_FRESHNESS_MS = BUBBLE_LIFETIME_MS + 1000;

type VisibleBubble = AgentActionItem & { exiting?: boolean };

export default function AgentActivityBubbles({ instanceId }: { instanceId: string }) {
  const buffer = useSelector((state: any) => selectAgentActivityBuffer(state, instanceId));
  const [visible, setVisible] = useState<VisibleBubble[]>([]);

  // Ids we've already surfaced (replayed or live) so the live effect never
  // double-shows a buffered item. Reset when the viewed instance changes.
  const seenIdsRef = useRef<Set<string>>(new Set());
  // All pending timers, cleared on unmount / instance switch.
  const timersRef = useRef<number[]>([]);

  // Show one bubble now and schedule its fade-out (exiting) + removal after 4s.
  // Stable across renders (only touches refs/setState), so both effects share it.
  const pushVisible = useCallback((item: AgentActionItem) => {
    setVisible((prev) => (prev.some((b) => b.id === item.id) ? prev : [...prev, item]));
    const hideTimer = window.setTimeout(() => {
      setVisible((prev) => prev.map((b) => (b.id === item.id ? { ...b, exiting: true } : b)));
      const removeTimer = window.setTimeout(() => {
        setVisible((prev) => prev.filter((b) => b.id !== item.id));
      }, EXIT_ANIM_MS);
      timersRef.current.push(removeTimer);
    }, BUBBLE_LIFETIME_MS);
    timersRef.current.push(hideTimer);
  }, []);

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

  if (visible.length === 0) return null;

  return (
    <div
      data-debug-id="conversation-activity-bubbles"
      className="pointer-events-none mb-1 flex flex-wrap items-center gap-1.5 px-1"
      aria-hidden="true"
    >
      {visible.map((bubble) => (
        <span
          key={bubble.id}
          data-debug-id={`conversation-activity-bubble-${bubble.action || 'action'}`}
          title={bubble.summary}
          className={`inline-flex max-w-[240px] items-center rounded-full border border-white/10 bg-white/[0.04] px-2.5 py-1 text-[11px] leading-none text-zinc-400 ${bubble.exiting ? 'agent-bubble-exit' : 'agent-bubble-enter'}`}
        >
          <span className="truncate">{bubble.summary}</span>
        </span>
      ))}
    </div>
  );
}
