import { useEffect, useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { Modal } from '@ui';
import { useCreateShellMutation } from '../../api/endpoints/shells';
import type { ShellSessionKind } from '../../api/endpoints/shells';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { bridgeIdOf, bridgeIsOnline, bridgeLabel } from '../../utils/bridgeLaunchOptions';

interface NewShellDialogProps {
  // T11-UI-2: optional. When the caller has no bridge in hand the dialog picks one
  // itself from the bridge dropdown below, so nobody has to paste a raw bridge id.
  bridgeId?: string;
  // T11-UI-3: optional. Callers that already know their chain (the chain overview)
  // pass it; the sidebar tab does not, and the dialog then tags the new shell with
  // whichever chain the main view currently has focused.
  chainId?: string;
  onClose: () => void;
  onCreated?: (sessionId: string) => void;
}

const KIND_OPTIONS: { value: ShellSessionKind; label: string; description: string }[] = [
  { value: 'interactive', label: 'Interactive', description: 'PTY shell with terminal' },
  { value: 'command', label: 'Command', description: 'One-shot command with log output' },
  { value: 'server', label: 'Server', description: 'Long-running server with preview' },
  { value: 'agent', label: 'Agent', description: 'Agent PTY session' },
];

// The dialog's action row lives in Modal.Footer, outside the <form> element, so
// the submit button reaches the form by id.
const FORM_ID = 'new-shell-dialog-form';

// Touch-target floor for every control in the form (the 44px convention used
// across the settings panels).
const FIELD_CLASS =
  'min-h-[44px] w-full rounded border border-subtle bg-surface px-2 py-1.5 text-xs text-primary placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent';

export function NewShellDialog({ bridgeId, chainId, onClose, onCreated }: NewShellDialogProps) {
  const [kind, setKind] = useState<ShellSessionKind>('interactive');
  const [cmd, setCmd] = useState('');
  const [cwd, setCwd] = useState('');
  const [label, setLabel] = useState('');
  const [port, setPort] = useState('');
  const [selectedBridgeId, setSelectedBridgeId] = useState(bridgeId || '');

  // T11-UI-3: an explicit chain from the caller wins; otherwise fall back to the
  // focused chain. Empty means the shell is created untagged.
  const focusedChainId = useSelector((state: any) => state.chainView?.focusedChainId || '');
  const effectiveChainId = chainId || focusedChainId;

  const bridgesQuery = useListBridgesQuery();
  // Revoked bridges can't host a shell, so they never reach the dropdown; online
  // ones sort first so the default pick is a bridge that can actually answer.
  const bridges: any[] = useMemo(() => {
    const all: any[] = bridgesQuery.data?.bridges || [];
    return all
      .filter((bridge) => String(bridge?.status || '').toLowerCase() !== 'revoked')
      .slice()
      .sort((a, b) => Number(bridgeIsOnline(b)) - Number(bridgeIsOnline(a)));
  }, [bridgesQuery.data]);

  // Default to the caller's bridge when it is still a valid choice, else the first
  // online bridge. Runs only while nothing is selected, so it never fights the user.
  useEffect(() => {
    if (selectedBridgeId || bridges.length === 0) return;
    const preferred = bridgeId && bridges.some((bridge) => bridgeIdOf(bridge) === bridgeId)
      ? bridgeId
      : bridgeIdOf(bridges.find(bridgeIsOnline) || bridges[0]);
    if (preferred) setSelectedBridgeId(preferred);
  }, [bridges, bridgeId, selectedBridgeId]);

  const [createShell, createState] = useCreateShellMutation();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedBridgeId) return;
    try {
      const session = await createShell({
        bridgeId: selectedBridgeId,
        kind,
        cmd: cmd || undefined,
        cwd: cwd || undefined,
        label: label || undefined,
        server_port: kind === 'server' && port ? Number(port) : undefined,
        chain_id: effectiveChainId || undefined,
      }).unwrap();
      onCreated?.(session.session_id);
      onClose();
    } catch { /* error shown via createState.error */ }
  };

  return (
    <Modal
      open
      onOpenChange={(next) => { if (!next) onClose(); }}
      title="New Shell Session"
      size="sm"
      data-debug-id="new-shell-dialog"
    >
      <Modal.Body className="text-xs text-primary">
        <form id={FORM_ID} onSubmit={handleSubmit}>
          {/* Bridge (T11-UI-2) */}
          <div className="mb-3">
            <label htmlFor="new-shell-bridge" className="mb-1 block font-semibold text-muted">Bridge</label>
            <select
              id="new-shell-bridge"
              data-debug-id="new-shell-dialog-bridge-select"
              value={selectedBridgeId}
              onChange={(e) => setSelectedBridgeId(e.target.value)}
              disabled={bridgesQuery.isLoading}
              className={FIELD_CLASS}
            >
              <option value="">
                {bridgesQuery.isLoading
                  ? 'Loading bridges…'
                  : bridges.length === 0 ? 'No bridges available' : 'Select a bridge…'}
              </option>
              {bridges.map((bridge) => {
                const id = bridgeIdOf(bridge);
                return (
                  <option key={id} value={id}>
                    {bridgeLabel(bridge)}{bridgeIsOnline(bridge) ? '' : ' (offline)'}
                  </option>
                );
              })}
            </select>
            {effectiveChainId && (
              <p className="mt-1 text-[10px] text-faint">
                Tagged with chain <span className="font-mono">{effectiveChainId}</span>
              </p>
            )}
          </div>

          {/* Kind */}
          <div className="mb-3">
            <label className="mb-1 block font-semibold text-muted">Kind</label>
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
              {KIND_OPTIONS.map((opt) => (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => setKind(opt.value)}
                  aria-pressed={kind === opt.value ? 'true' : 'false'}
                  className={`min-h-[44px] rounded border px-3 py-2 text-left text-xs transition-colors ${
                    kind === opt.value
                      ? 'border-accent bg-accent/10 font-semibold text-accent'
                      : 'border-subtle bg-surface-raised text-muted hover:border-accent/50 hover:text-primary'
                  }`}
                >
                  <div className="font-semibold">{opt.label}</div>
                  <div className="text-[10px] opacity-70">{opt.description}</div>
                </button>
              ))}
            </div>
          </div>

          {/* Command */}
          <div className="mb-3">
            <label htmlFor="new-shell-cmd" className="mb-1 block font-semibold text-muted">
              Command {kind === 'interactive' ? '(optional — default shell)' : ''}
            </label>
            <input
              id="new-shell-cmd"
              type="text"
              placeholder={kind === 'interactive' ? 'e.g. bash' : kind === 'server' ? 'e.g. python -m http.server' : 'e.g. npm test'}
              value={cmd}
              onChange={(e) => setCmd(e.target.value)}
              className={FIELD_CLASS}
            />
          </div>

          {/* Working directory */}
          <div className="mb-3">
            <label htmlFor="new-shell-cwd" className="mb-1 block font-semibold text-muted">Working directory (optional)</label>
            <input
              id="new-shell-cwd"
              type="text"
              placeholder="e.g. ~/my-project"
              value={cwd}
              onChange={(e) => setCwd(e.target.value)}
              className={FIELD_CLASS}
            />
          </div>

          {/* Label */}
          <div className="mb-3">
            <label htmlFor="new-shell-label" className="mb-1 block font-semibold text-muted">Label (optional)</label>
            <input
              id="new-shell-label"
              type="text"
              placeholder="e.g. Dev server"
              value={label}
              onChange={(e) => setLabel(e.target.value)}
              className={FIELD_CLASS}
            />
          </div>

          {/* Port (server kind only) */}
          {kind === 'server' && (
            <div className="mb-3">
              <label htmlFor="new-shell-port" className="mb-1 block font-semibold text-muted">Port (optional)</label>
              <input
                id="new-shell-port"
                type="number"
                inputMode="numeric"
                placeholder="e.g. 3000"
                value={port}
                onChange={(e) => setPort(e.target.value)}
                min="1"
                max="65535"
                className={FIELD_CLASS}
              />
            </div>
          )}

          {createState.isError && (
            <div className="rounded border border-danger/40 bg-danger/10 px-2 py-1.5 text-xs text-danger">
              {String((createState.error as any)?.error || 'Failed to create shell session')}
            </div>
          )}
        </form>
      </Modal.Body>

      <Modal.Footer>
        <button
          type="button"
          onClick={onClose}
          className="min-h-[44px] rounded border border-subtle px-3 text-xs font-semibold text-muted hover:text-primary"
        >
          Cancel
        </button>
        <button
          type="submit"
          form={FORM_ID}
          disabled={createState.isLoading || !selectedBridgeId}
          className="min-h-[44px] rounded bg-accent px-3 text-xs font-semibold text-white hover:opacity-90 disabled:opacity-50"
        >
          {createState.isLoading ? 'Creating…' : 'Create Shell'}
        </button>
      </Modal.Footer>
    </Modal>
  );
}
