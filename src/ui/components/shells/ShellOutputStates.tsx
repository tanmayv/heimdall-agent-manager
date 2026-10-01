import type { ShellLogError } from '../../api/endpoints/shells';

/**
 * REQ-SHELL-6 §7 — the three output states, in ONE place.
 *
 * Two surfaces read a shell session's output: the full log viewer and the run
 * indicator's expanded block. Both must render §7's three states, and both must render
 * them the SAME way — the requirement is that the states are distinguishable, which a
 * second divergent copy of the wording quietly undermines. So the panes live here and
 * the callers position them.
 *
 * The distinction itself is not derivable from the content: "no lines" is the same pixel
 * for a reclaimed log, an unreachable bridge and a command that printed nothing. It
 * comes from the hub's ERROR CODE, carried through by `getShellLog`
 * (shell_session_service.odin:1037-1046).
 */

/** Pull the typed failure out of an RTK Query error, or undefined if there was none. */
export function shellLogFailure(error: unknown): ShellLogError | undefined {
  const data = (error as any)?.data;
  return data?.reason ? (data as ShellLogError) : undefined;
}

interface UnavailableProps {
  failure: ShellLogError;
  onRetry?: () => void;
  isFetching?: boolean;
  /** Prefixes the data-debug-id so each state is addressable per surface. */
  debugPrefix: string;
}

/**
 * States 1 and 2 of 3: the output could not be read, and WHY decides what we offer.
 *
 * The retry is the load-bearing difference, not the colour. `bridge_offline` is
 * transient — the output still exists and the bridge may reconnect at any moment — so a
 * retry is honest. `gone` is permanent: retention reclaimed the file and it can never
 * come back, so offering a retry would imply otherwise. Getting that backwards is how
 * two genuinely different outcomes end up reading as one "something went wrong" pane.
 */
export function ShellOutputUnavailable({ failure, onRetry, isFetching, debugPrefix }: UnavailableProps) {
  if (failure.reason === 'bridge_offline') {
    return (
      <div
        data-debug-id={`${debugPrefix}-bridge-offline`}
        className="rounded border border-warning/40 bg-warning-soft px-2 py-1.5 text-[11px] text-warning"
      >
        <div className="font-semibold">Output unavailable right now</div>
        <div className="mt-0.5 font-sans text-muted">
          The bridge hosting this session is offline, so its output cannot be read. It is
          not lost — try again once the bridge reconnects.
        </div>
        {onRetry && <RetryButton onRetry={onRetry} isFetching={isFetching} debugPrefix={debugPrefix} />}
      </div>
    );
  }

  if (failure.reason === 'gone') {
    return (
      <div
        data-debug-id={`${debugPrefix}-reclaimed`}
        className="rounded border border-subtle bg-surface-raised px-2 py-1.5 text-[11px] text-muted"
      >
        <div className="font-semibold text-primary">Output no longer available</div>
        <div className="mt-0.5 font-sans">
          This session's output passed its retention window and has been reclaimed. It
          cannot be recovered.
        </div>
      </div>
    );
  }

  // Anything else: the hub's own sentence, with no guess at whether it is recoverable.
  return (
    <div
      data-debug-id={`${debugPrefix}-error`}
      className="rounded border border-danger/40 bg-danger/10 px-2 py-1.5 text-[11px] text-danger"
    >
      <div className="font-semibold">Could not load output</div>
      <div className="mt-0.5 font-sans break-words">{failure.message}</div>
      {onRetry && <RetryButton onRetry={onRetry} isFetching={isFetching} debugPrefix={debugPrefix} />}
    </div>
  );
}

function RetryButton({ onRetry, isFetching, debugPrefix }: { onRetry: () => void; isFetching?: boolean; debugPrefix: string }) {
  return (
    <button
      type="button"
      onClick={onRetry}
      disabled={isFetching}
      data-debug-id={`${debugPrefix}-retry`}
      className="mt-1 rounded bg-neutral-soft px-2 py-0.5 font-sans text-[10px] font-semibold text-primary hover:opacity-80 disabled:opacity-40"
    >
      {isFetching ? 'Retrying…' : 'Try again'}
    </button>
  );
}

/**
 * State 3 of 3: GENUINELY EMPTY, and a SUCCESS rather than a failure — the request
 * answered 200 with zero lines, so the command really did print nothing. Callers must
 * gate this on the absence of a failure so it can never stand in for one.
 *
 * The live and terminal wordings differ deliberately: "nothing yet" and "nothing at
 * all" are different facts, and collapsing them would make a running job that has not
 * printed yet look like one that never will.
 */
export function ShellOutputEmpty({ isRunning, grep, debugPrefix }: { isRunning?: boolean; grep?: string; debugPrefix: string }) {
  return (
    <div data-debug-id={`${debugPrefix}-empty`} className="text-xs text-faint italic">
      {grep ? 'No matching lines.' : isRunning ? 'No output yet.' : 'This command produced no output.'}
    </div>
  );
}
