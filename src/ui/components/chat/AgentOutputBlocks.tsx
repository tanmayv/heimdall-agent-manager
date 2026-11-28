import React, { useState } from 'react';
import { useSelector } from 'react-redux';
import { selectAgentOutputTurns, type AgentOutputSegment, type AgentOutputTurn } from '../../store/agentOutputSlice';
import { useDecryptedText } from '../vault/VaultText';

// G12: the agent's streamed output, shown under the last message in a muted
// block while its turn streams. A finished turn collapses to one line the user
// can expand. Nothing here is a message: replies arrive through `chat send`.
// The data lives only in the agentOutput slice (UI memory), so a reload or a
// fresh mount without live events shows nothing.

function debugKey(turnKey: string): string {
  return turnKey.replace(/[^A-Za-z0-9_-]+/g, '-');
}

type PlanStep = { text: string; status: string };

// ACP `plan` updates carry entries[{content,status}]; Codex turn/plan/updated
// carries plan[{step,status}]. Anything else renders nothing.
export function parsePlanSteps(text: string): PlanStep[] {
  try {
    const raw = JSON.parse(text);
    const list = Array.isArray(raw?.entries) ? raw.entries : Array.isArray(raw?.plan) ? raw.plan : [];
    return list
      .map((entry: any) => ({ text: String(entry?.content ?? entry?.step ?? ''), status: String(entry?.status ?? '') }))
      .filter((step: PlanStep) => step.text);
  } catch {
    return [];
  }
}

const PLAN_MARK: Record<string, string> = { completed: '☑', in_progress: '◐', inProgress: '◐' };

function SegmentText({ segment, debugId }: { segment: AgentOutputSegment; debugId: string }) {
  const { text } = useDecryptedText(segment.body);
  if (segment.kind === 'plan') {
    const steps = parsePlanSteps(text);
    if (!steps.length) return null;
    return (
      <ul data-debug-id={`${debugId}-plan`} className="space-y-0.5">
        {steps.map((step, index) => (
          <li key={index} className="flex gap-1.5"><span aria-hidden="true">{PLAN_MARK[step.status] ?? '☐'}</span><span className="min-w-0 break-words">{step.text}</span></li>
        ))}
      </ul>
    );
  }
  if (segment.kind === 'thought') {
    return <div data-debug-id={`${debugId}-thought`} className="whitespace-pre-wrap break-words italic text-faint">{text}</div>;
  }
  return <div className="whitespace-pre-wrap break-words">{text}</div>;
}

function FirstLine({ segment }: { segment: AgentOutputSegment | undefined }) {
  const { text } = useDecryptedText(segment?.body ?? '');
  const line = text.split('\n').map((part) => part.trim()).find(Boolean) ?? '';
  return <span className="min-w-0 truncate">{line}</span>;
}

// Plan first, then thoughts, then the assistant text in turn order.
const KIND_ORDER: Record<string, number> = { plan: 0, thought: 1 };
function orderedSegments(turn: AgentOutputTurn): AgentOutputSegment[] {
  return turn.segments
    .filter((segment) => segment.body)
    .slice()
    .sort((a, b) => (KIND_ORDER[a.kind] ?? 2) - (KIND_ORDER[b.kind] ?? 2) || a.index - b.index);
}

function TurnBlock({ turn }: { turn: AgentOutputTurn }) {
  const [expanded, setExpanded] = useState(false);
  const key = debugKey(turn.turnKey);
  const segments = orderedSegments(turn);
  const summarySegment = segments.find((segment) => segment.kind === 'text') ?? segments.find((segment) => segment.kind === 'thought');
  if (!turn.finished) {
    return (
      <div
        data-debug-id={`conversation-agent-output-live-${key}`}
        aria-live="polite"
        className="agent-output-block ml-1 max-w-full border-l-2 border-border pl-3 text-xs leading-relaxed text-muted opacity-80"
      >
        <div className="mb-1 text-[11px] uppercase tracking-wide text-faint">Working…</div>
        <div className="space-y-2">
          {segments.map((segment) => <SegmentText key={segment.messageId} segment={segment} debugId={`conversation-agent-output-${key}`} />)}
        </div>
      </div>
    );
  }
  const label = turn.failed ? 'Interrupted' : 'Worked';
  return (
    <div className="agent-output-block ml-1 max-w-full text-xs text-faint">
      <button
        type="button"
        data-debug-id={`conversation-agent-output-summary-${key}`}
        aria-expanded={expanded}
        onClick={() => setExpanded((value) => !value)}
        className="flex max-w-full items-center gap-1.5 rounded px-1 py-0.5 text-left text-faint hover:text-muted"
      >
        <span aria-hidden="true">{expanded ? '▾' : '▸'}</span>
        <span className="shrink-0">{label}</span>
        {!expanded && summarySegment && <span aria-hidden="true">·</span>}
        {!expanded && <FirstLine segment={summarySegment} />}
      </button>
      {expanded && (
        <div
          data-debug-id={`conversation-agent-output-expanded-${key}`}
          className="mt-1 space-y-2 border-l-2 border-border pl-3 leading-relaxed text-muted opacity-80"
        >
          {segments.map((segment) => <SegmentText key={segment.messageId} segment={segment} debugId={`conversation-agent-output-${key}`} />)}
        </div>
      )}
    </div>
  );
}

export default function AgentOutputBlocks({ conversationId }: { conversationId: string | null | undefined }) {
  const turns = useSelector((state: any) => selectAgentOutputTurns(state, conversationId));
  if (!turns.length) return null;
  return (
    <div data-debug-id="conversation-agent-output" className="flex flex-col gap-1.5">
      {turns.map((turn) => <TurnBlock key={turn.turnKey} turn={turn} />)}
    </div>
  );
}
