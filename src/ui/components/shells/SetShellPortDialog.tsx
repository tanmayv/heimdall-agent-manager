import { useState } from 'react';
import { Modal } from '@ui';
import { useSetShellPortMutation } from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';

interface SetShellPortDialogProps {
  session: ShellSession;
  onClose: () => void;
}

// The dialog's action row lives in Modal.Footer, outside the <form>, so the submit
// button reaches the form by id — the same arrangement NewShellDialog uses.
const FORM_ID = 'set-shell-port-form';

// Same 44px touch floor and field styling as NewShellDialog, so the two shell
// dialogs look like one feature rather than two.
const FIELD_CLASS =
  'min-h-[44px] w-full rounded border border-subtle bg-surface px-2 py-1.5 text-xs text-primary placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent';

// XM-9: declare the port of a session that is ALREADY running — the workflow where
// you open a terminal and only then start a server in it, so there was no port to
// declare at start time.
//
// A Modal rather than a window.prompt: this takes a value, and every other
// value-taking flow in the app is a Modal. window.confirm stays reserved for the
// yes/no destructive confirms (the Kill item next to this one).
export function SetShellPortDialog({ session, onClose }: SetShellPortDialogProps) {
  const [port, setPort] = useState(session.server_port > 0 ? String(session.server_port) : '');
  const [setShellPort, state] = useSetShellPortMutation();

  const parsed = Number(port);
  // An empty field is not a clear — clearing is its own button, so that a mistyped
  // field can never silently make a reachable session unreachable.
  const valid = port.trim() !== '' && Number.isInteger(parsed) && parsed >= 1 && parsed <= 65535;

  const submit = async (server_port: number) => {
    try {
      await setShellPort({ sessionId: session.session_id, server_port }).unwrap();
      onClose();
    } catch { /* error shown via state.error */ }
  };

  return (
    <Modal
      open
      onOpenChange={(next) => { if (!next) onClose(); }}
      title="Set Server Port"
      size="sm"
      data-debug-id="set-shell-port-dialog"
    >
      <Modal.Body className="text-xs text-primary">
        <form
          id={FORM_ID}
          onSubmit={(e) => { e.preventDefault(); if (valid) void submit(parsed); }}
        >
          <p className="mb-3 text-[11px] text-muted">
            The port a server inside{' '}
            <span className="font-mono text-primary">{session.label || session.cmd || session.session_id}</span>{' '}
            is listening on. Declaring it here makes the session reachable immediately —
            no restart. The port is read from the session, never from the request that
            opens the connection.
          </p>

          <label htmlFor="set-shell-port-input" className="mb-1 block font-semibold text-muted">Port</label>
          <input
            id="set-shell-port-input"
            data-debug-id="set-shell-port-dialog-input"
            type="number"
            inputMode="numeric"
            placeholder="e.g. 3000"
            value={port}
            onChange={(e) => setPort(e.target.value)}
            min="1"
            max="65535"
            autoFocus
            className={FIELD_CLASS}
          />

          {state.isError && (
            <div className="mt-3 rounded border border-danger/40 bg-danger/10 px-2 py-1.5 text-xs text-danger">
              {String((state.error as any)?.error || 'Failed to set the port')}
            </div>
          )}
        </form>
      </Modal.Body>

      {/* flex-wrap so the three actions drop to a second line instead of overflowing
          the panel on a narrow phone or at a large browser text size — the row fits
          at 320px as-is, but nothing here depends on that holding. */}
      <Modal.Footer className="flex-wrap">
        <button
          type="button"
          onClick={onClose}
          className="min-h-[44px] rounded border border-subtle px-3 text-xs font-semibold text-muted hover:text-primary"
        >
          Cancel
        </button>
        {session.server_port > 0 && (
          <button
            type="button"
            data-debug-id="set-shell-port-dialog-clear"
            onClick={() => void submit(0)}
            disabled={state.isLoading}
            className="min-h-[44px] rounded border border-danger/40 px-3 text-xs font-semibold text-danger hover:bg-danger/10 disabled:opacity-50"
          >
            Clear port
          </button>
        )}
        <button
          type="submit"
          form={FORM_ID}
          disabled={state.isLoading || !valid}
          className="min-h-[44px] rounded bg-accent px-3 text-xs font-semibold text-white hover:opacity-90 disabled:opacity-50"
        >
          {state.isLoading ? 'Saving…' : 'Set port'}
        </button>
      </Modal.Footer>
    </Modal>
  );
}
