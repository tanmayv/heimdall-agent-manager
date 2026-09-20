import { useState } from 'react';
import { useCreateShellMutation } from '../../api/endpoints/shells';
import type { ShellSessionKind } from '../../api/endpoints/shells';

interface NewShellDialogProps {
  bridgeId: string;
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

export function NewShellDialog({ bridgeId, chainId, onClose, onCreated }: NewShellDialogProps) {
  const [kind, setKind] = useState<ShellSessionKind>('interactive');
  const [cmd, setCmd] = useState('');
  const [cwd, setCwd] = useState('');
  const [label, setLabel] = useState('');
  const [port, setPort] = useState('');

  const [createShell, createState] = useCreateShellMutation();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!bridgeId) return;
    try {
      const session = await createShell({
        bridgeId,
        kind,
        cmd: cmd || undefined,
        cwd: cwd || undefined,
        label: label || undefined,
        server_port: kind === 'server' && port ? Number(port) : undefined,
        chain_id: chainId || undefined,
      }).unwrap();
      onCreated?.(session.session_id);
      onClose();
    } catch { /* error shown via createState.error */ }
  };

  return (
    <div
      data-debug-id="new-shell-dialog-backdrop"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40"
      onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}
    >
      <form
        data-debug-id="new-shell-dialog"
        onSubmit={handleSubmit}
        className="w-full max-w-md rounded-xl border border-subtle bg-surface p-5 shadow-panel text-xs text-primary"
      >
        <h2 className="mb-4 text-sm font-bold text-primary">New Shell Session</h2>

        {/* Kind */}
        <div className="mb-3">
          <label className="mb-1 block font-semibold text-muted">Kind</label>
          <div className="grid grid-cols-2 gap-2">
            {KIND_OPTIONS.map((opt) => (
              <button
                key={opt.value}
                type="button"
                onClick={() => setKind(opt.value)}
                className={`rounded border px-3 py-2 text-left text-xs transition-colors ${
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
          <label className="mb-1 block font-semibold text-muted">
            Command {kind === 'interactive' ? '(optional — default shell)' : ''}
          </label>
          <input
            type="text"
            placeholder={kind === 'interactive' ? 'e.g. bash' : kind === 'server' ? 'e.g. python -m http.server' : 'e.g. npm test'}
            value={cmd}
            onChange={(e) => setCmd(e.target.value)}
            className="w-full rounded border border-subtle bg-surface px-2 py-1.5 text-xs placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent"
          />
        </div>

        {/* Working directory */}
        <div className="mb-3">
          <label className="mb-1 block font-semibold text-muted">Working directory (optional)</label>
          <input
            type="text"
            placeholder="e.g. ~/my-project"
            value={cwd}
            onChange={(e) => setCwd(e.target.value)}
            className="w-full rounded border border-subtle bg-surface px-2 py-1.5 text-xs placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent"
          />
        </div>

        {/* Label */}
        <div className="mb-3">
          <label className="mb-1 block font-semibold text-muted">Label (optional)</label>
          <input
            type="text"
            placeholder="e.g. Dev server"
            value={label}
            onChange={(e) => setLabel(e.target.value)}
            className="w-full rounded border border-subtle bg-surface px-2 py-1.5 text-xs placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent"
          />
        </div>

        {/* Port (server kind only) */}
        {kind === 'server' && (
          <div className="mb-3">
            <label className="mb-1 block font-semibold text-muted">Port (optional)</label>
            <input
              type="number"
              placeholder="e.g. 3000"
              value={port}
              onChange={(e) => setPort(e.target.value)}
              min="1"
              max="65535"
              className="w-full rounded border border-subtle bg-surface px-2 py-1.5 text-xs placeholder:text-faint focus:outline-none focus:ring-1 focus:ring-accent"
            />
          </div>
        )}

        {createState.isError && (
          <div className="mb-3 rounded border border-danger/40 bg-danger/10 px-2 py-1.5 text-xs text-danger">
            {String((createState.error as any)?.error || 'Failed to create shell session')}
          </div>
        )}

        <div className="flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded border border-subtle px-3 py-1.5 text-xs font-semibold text-muted hover:text-primary"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={createState.isLoading || !bridgeId}
            className="rounded bg-accent px-3 py-1.5 text-xs font-semibold text-white hover:opacity-90 disabled:opacity-50"
          >
            {createState.isLoading ? 'Creating…' : 'Create Shell'}
          </button>
        </div>
      </form>
    </div>
  );
}
