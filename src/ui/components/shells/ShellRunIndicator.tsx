import React from 'react';
import {
  useBackgroundShellMutation,
  useGetShellLogQuery,
  useKillShellMutation,
  useListShellsQuery,
} from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';
import { isTerminal, killAffordance, pinnedRunSessions, statusPresentation, type ShellRunMarker } from './shellModel';
import { ShellOutputEmpty, ShellOutputUnavailable, shellLogFailure } from './ShellOutputStates';
import type { ChatMessage, ChatTimestamp } from '../chat/types';

/**
 * REQ-SHELL-6 §2/§3 — the RUN INDICATOR.
 *
 * The task calls this a "run card"; the user explicitly asked for the opposite of a card
 * ("ensure that agent use this subtle indicator… all running jobs are at the end of
 * conversation and above the composer"), with Claude Code's own transcript as the
 * reference. So this is a transcript ROW, not a panel with chrome:
 *
 *   LIVE      one dim line, present tense, with a spinner: "Run <cmd>"
 *   FINISHED  past tense and collapsed: "Ran <cmd> ›", expandable to the command and
 *             its output
 *   SEVERAL   collapse into one group row: "Ran N commands ⌄"
 *
 * WHERE THE TRUTH LIVES, and why this design is cheap. REQ-SHELL-5 emits the marker
 * message ONCE at run creation with metadata_json={"session_id":…} and deliberately puts
 * NO STATUS IN THE MESSAGE. Everything below — the tense, the spinner, the exit state,
 * whether it is pinned — resolves live from the shell_sessions row. So a status change
 * never requires editing or deleting a transcript message; it is a rendering decision,
 * which is exactly what makes pin-while-live / collapse-when-done implementable at all.
 * This follows the lean-message precedent set by message_type "pane_capture"
 * (ConversationThreadPage.tsx:1321).
 *
 * HOW THE ROWS ARE RESOLVED. One query, not one per marker: `run` is AGENT-scoped
 * (shell_session.odin:88, key = {.Agent_Instance}), so GET /shells?agent_instance_id=…
 * returns exactly this agent's runs and structurally cannot return a shell or a server.
 * That keeps this to a single RTK cache entry — which matters because §6 removed every
 * poller, and one entry means one push invalidation repaints every row at once.
 */

/* The pin decision and the marker shape now live in shellModel, so they can be tested
 * as real code without mounting React — see the note there. Re-exported because callers
 * of this module (ConversationThreadPage) want both from one import. */
export { pinnedRunSessions, type ShellRunMarker };

/** Trim a command to one line's worth; the row must never wrap (reference item 2). */
function oneLine(cmd: string): string {
  return (cmd || '').replace(/\s+/g, ' ').trim();
}

export function useConversationRuns(agentInstanceId: string, conversationId: string): ShellSession[] {
  const { data } = useListShellsQuery(
    { agentInstanceId, limit: 50 },
    { skip: !agentInstanceId },
  );
  return React.useMemo(() => {
    const rows = data?.sessions ?? [];
    // kind is belt-and-braces — the scope rule already guarantees it — but
    // conversation_id is a REAL narrowing: the chain's CONVERSATION SCOPE decision says a
    // run appears ONLY in the conversation that triggered it, and one agent instance can
    // in principle have runs recorded against more than one conversation id.
    return rows.filter((s) => s.kind === 'run' && (!conversationId || s.conversation_id === conversationId));
  }, [data, conversationId]);
}

/* ------------------------------------------------------------------ *
 * One run's row
 * ------------------------------------------------------------------ */

interface RunRowProps {
  session: ShellSession;
  /** Expanded by default only when the caller says so (a lone finished run stays shut). */
  defaultExpanded?: boolean;
}

export function ShellRunRow({ session, defaultExpanded = false }: RunRowProps) {
  const [expanded, setExpanded] = React.useState(defaultExpanded);
  const terminal = isTerminal(session);
  const presentation = statusPresentation(session);
  const cmd = oneLine(session.cmd) || session.label || session.session_id;

  return (
    <div data-debug-id={`shell-run-${session.session_id}`} className="min-w-0 text-[12px]">
      <div className="flex min-w-0 items-center gap-1.5">
        <button
          type="button"
          onClick={() => setExpanded((v) => !v)}
          data-debug-id={`shell-run-toggle-${session.session_id}`}
          aria-expanded={expanded}
          className="flex min-w-0 flex-1 items-center gap-1.5 rounded px-1 py-0.5 text-left text-muted hover:bg-neutral-soft hover:text-primary"
        >
          {/* Verb + command and nothing else on the collapsed line — no exit code, no
              duration, no status badge. The reference conveys success by the absence of
              alarm rather than by a tick, and a failure is simply its output. */}
          <span className="shrink-0 font-sans">{terminal ? 'Ran' : 'Run'}</span>
          {/* truncate + min-w-0 is what holds it to ONE line however long the command
              is; the reference cuts mid-path rather than wrapping. */}
          <span className="min-w-0 flex-1 truncate font-mono" title={session.cmd}>
            {cmd}
          </span>
          {presentation.unknown ? (
            // REQ-SHELL-6 §8: never a spinner here. A spinner asserts "still going",
            // which is the one thing an offline bridge means we cannot claim.
            <span
              data-debug-id={`shell-run-status-unknown-${session.session_id}`}
              title={presentation.title}
              className="shrink-0 rounded bg-warning-soft px-1 py-0.5 text-[10px] font-semibold text-warning"
            >
              status unknown
            </span>
          ) : terminal ? (
            <span className="shrink-0 text-faint" aria-hidden="true">{expanded ? '⌄' : '›'}</span>
          ) : (
            <span
              data-debug-id={`shell-run-spinner-${session.session_id}`}
              title="Running"
              className="h-2.5 w-2.5 shrink-0 animate-spin rounded-full border border-muted border-t-transparent"
            />
          )}
        </button>
        <RunControls session={session} />
      </div>

      {expanded && <RunOutput session={session} />}
    </div>
  );
}

/**
 * The two controls a live run offers: convert to background (§3) and kill (§8).
 *
 * Both are deliberately absent once the run is terminal — there is nothing left to
 * background and nothing left to kill — which is also why §3's "it disappears once the
 * run is terminal or already background" needs no separate state.
 */
function RunControls({ session }: { session: ShellSession }) {
  const [backgroundShell, bgState] = useBackgroundShellMutation();
  const [killShell, killState] = useKillShellMutation();
  const terminal = isTerminal(session);
  const kill = killAffordance(session);

  if (terminal) return null;

  return (
    <span className="flex shrink-0 items-center gap-1">
      {/* §3 BACKGROUND TOGGLE. Offered only while the run is live AND still foreground:
          the conversion is one-way, so a run already backgrounded has no control to
          show. The hub enforces both conditions with a 409
          (shell_session_rest_handlers.odin:195-227); this only decides whether to ask. */}
      {!session.background && (
        <button
          type="button"
          onClick={() => { void backgroundShell({ sessionId: session.session_id }); }}
          disabled={bgState.isLoading}
          data-debug-id={`shell-run-background-${session.session_id}`}
          title="Let this run continue in the background. You will be notified when it finishes."
          className="rounded px-1.5 py-0.5 text-[10px] font-semibold text-accent hover:bg-accent/10 disabled:opacity-40"
        >
          {bgState.isLoading ? '…' : 'Background'}
        </button>
      )}
      {session.background && (
        <span
          data-debug-id={`shell-run-is-background-${session.session_id}`}
          title="Running in the background — you will be notified when it finishes."
          className="rounded bg-neutral-soft px-1.5 py-0.5 text-[10px] font-semibold text-muted"
        >
          background
        </span>
      )}
      {kill.offered && (
        <button
          type="button"
          onClick={() => { void killShell({ sessionId: session.session_id }); }}
          disabled={killState.isLoading}
          data-debug-id={`shell-run-kill-${session.session_id}`}
          title={kill.title}
          className="rounded px-1.5 py-0.5 text-[10px] font-semibold text-danger hover:bg-danger/10 disabled:opacity-40"
        >
          {killState.isLoading ? '…' : kill.label}
        </button>
      )}
      {/* §8: when the bridge is gone the kill is DURABLE, not impossible — verified
          across two disconnect/reconnect cycles by REQ-SHELL-23, which is what earns the
          wording the right to commit to the OUTCOME. So the control stays enabled and the
          note says the kill WILL be carried out on reconnect. Greying it out would imply
          the request cannot be made; softening the note back to "cannot be carried out"
          would under-promise a guarantee we now actually hold. The one thing the copy must
          not do is imply IMMEDIACY — delivery waits for the bridge, and the bridge may be
          gone a long time. `killAffordance` owns that wording; both directions are
          asserted in tests/ui/shell_req6_predicates.mjs. */}
      {kill.queuedNote && (
        <span
          data-debug-id={`shell-run-kill-queued-${session.session_id}`}
          className="text-[10px] text-warning"
        >
          {kill.queuedNote}
        </span>
      )}
    </span>
  );
}

/**
 * The expanded block: the command echoed, then its output — "stream output on demand"
 * (§2), fetched only when the row is actually opened, since this component does not
 * mount until `expanded`.
 */
function RunOutput({ session }: { session: ShellSession }) {
  const { data, error, isFetching, refetch } = useGetShellLogQuery({
    sessionId: session.session_id,
    limit: 200,
  });
  const failure = shellLogFailure(error);
  const lines = data?.lines ?? [];
  const running = !isTerminal(session);

  return (
    <div
      data-debug-id={`shell-run-output-${session.session_id}`}
      className="mt-1 ml-1 rounded border border-subtle bg-surface-raised px-2 py-1.5 font-mono text-[11px]"
    >
      {/* The command, prompt-prefixed by its cwd — the reference shows the expansion
          revealing BOTH the full command and its output. */}
      <div className="mb-1 truncate text-muted" title={`${session.cwd} $ ${session.cmd}`}>
        <span className="text-faint">{session.cwd ? `${session.cwd} $ ` : '$ '}</span>
        {session.cmd}
      </div>

      {failure ? (
        <ShellOutputUnavailable
          failure={failure}
          onRetry={() => refetch()}
          isFetching={isFetching}
          debugPrefix={`shell-run-log-${session.session_id}`}
        />
      ) : lines.length === 0 && !isFetching ? (
        <ShellOutputEmpty isRunning={running} debugPrefix={`shell-run-log-${session.session_id}`} />
      ) : (
        <>
          {running && (
            // Same honesty as the log viewer: with no poller this is a snapshot, and a
            // stale tail that looks live is worse than one marked as read-on-demand.
            <button
              type="button"
              onClick={() => refetch()}
              disabled={isFetching}
              data-debug-id={`shell-run-log-refresh-${session.session_id}`}
              className="mb-1 rounded bg-neutral-soft px-1.5 py-0.5 font-sans text-[10px] font-semibold text-muted hover:text-primary disabled:opacity-40"
            >
              {isFetching ? 'Reading…' : 'snapshot · refresh'}
            </button>
          )}
          <div className="max-h-64 overflow-y-auto whitespace-pre-wrap break-all text-primary">
            {lines.join('\n')}
          </div>
        </>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ *
 * The pinned strip above the composer
 * ------------------------------------------------------------------ */

/**
 * Every pinned run, stacked at the end of the conversation directly above the composer.
 *
 * Live runs always render individually — concurrent runs stack, and each needs its own
 * spinner and controls. Finished ones COLLAPSE INTO A GROUP once several accumulate
 * ("Ran N commands ⌄"), per the reference, so a burst of completed work costs one line
 * rather than N.
 */
export function PinnedShellRuns({ sessions }: { sessions: ShellSession[] }) {
  const [groupOpen, setGroupOpen] = React.useState(false);
  const live = sessions.filter((s) => !isTerminal(s));
  const finished = sessions.filter((s) => isTerminal(s));

  if (sessions.length === 0) return null;

  return (
    <div data-debug-id="shell-run-pinned" className="mb-2 space-y-0.5">
      {finished.length > 1 ? (
        <>
          <button
            type="button"
            onClick={() => setGroupOpen((v) => !v)}
            data-debug-id="shell-run-group-toggle"
            aria-expanded={groupOpen}
            className="flex w-full items-center gap-1.5 rounded px-1 py-0.5 text-left text-[12px] text-muted hover:bg-neutral-soft hover:text-primary"
          >
            <span>Ran {finished.length} commands</span>
            <span className="text-faint" aria-hidden="true">{groupOpen ? '⌄' : '›'}</span>
          </button>
          {groupOpen && finished.map((s) => <ShellRunRow key={s.session_id} session={s} />)}
        </>
      ) : (
        finished.map((s) => <ShellRunRow key={s.session_id} session={s} />)
      )}
      {live.map((s) => <ShellRunRow key={s.session_id} session={s} />)}
    </div>
  );
}

export interface ClubbedRunGroupProps {
  messages: ChatMessage[];
  runBySessionId: Map<string, ShellSession>;
  formatTimestamp?: (unixMs: number) => ChatTimestamp;
  defaultExpanded?: boolean;
}

/**
 * REQ-CLUB-RUN-COMMANDS-13: Clubbed group header component for consecutive shell runs (>= 2).
 * Displays 'Ran {N} commands • {startTime} – {endTime} ›' (collapsed by default).
 * When expanded, renders individual ShellRunRows in chronological order, with each
 * command independently expandable to view prompt, cwd, and log output.
 */
export function ClubbedRunGroup({
  messages,
  runBySessionId,
  formatTimestamp,
  defaultExpanded = false,
}: ClubbedRunGroupProps) {
  const [expanded, setExpanded] = React.useState(defaultExpanded);
  const count = messages.length;
  const firstMsg = messages[0];
  const lastMsg = messages[messages.length - 1];
  const startTime = formatTimestamp && firstMsg ? formatTimestamp(firstMsg.createdUnixMs).label : '';
  const endTime = formatTimestamp && lastMsg ? formatTimestamp(lastMsg.createdUnixMs).label : '';
  const timeRange = startTime && endTime ? `${startTime} – ${endTime}` : (startTime || endTime || '');

  return (
    <div data-debug-id="clubbed-run-group" className="min-w-0 text-[12px] my-1">
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        data-debug-id="clubbed-run-group-toggle"
        aria-expanded={expanded}
        className="flex w-full min-w-0 items-center gap-1.5 rounded px-1 py-0.5 text-left text-muted hover:bg-neutral-soft hover:text-primary cursor-pointer"
      >
        <span className="font-sans font-medium text-primary">Ran {count} commands</span>
        {timeRange ? (
          <>
            <span className="text-faint">•</span>
            <span className="text-faint font-mono text-[11px]">{timeRange}</span>
          </>
        ) : null}
        <span className="shrink-0 text-faint ml-auto" aria-hidden="true">{expanded ? '⌄' : '›'}</span>
      </button>
      {expanded && (
        <div data-debug-id="clubbed-run-group-items" className="mt-1 ml-2 pl-2 border-l border-subtle/50 space-y-1">
          {messages.map((msg) => {
            const sessionId = String(msg.metadata?.session_id || msg.metadata?.sessionId || '');
            const session = sessionId ? runBySessionId.get(sessionId) : undefined;
            if (!session) return null;
            return <ShellRunRow key={sessionId} session={session} defaultExpanded={false} />;
          })}
        </div>
      )}
    </div>
  );
}

