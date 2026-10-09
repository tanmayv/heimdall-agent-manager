import { useEffect, useState, type Dispatch, type SetStateAction } from 'react';
import { Button, Modal, ModalBody, ModalFooter, Spinner, StatusPill } from '@ui';
import {
  type ProviderSetupResponse,
  type ProviderTestRunResponse,
  providerSetupMockApi,
} from './providerSetupMockApi';

export interface ProviderTestTarget {
  provider: string;
  providerLabel: string;
  modelId: string;
  modelLabel: string;
  binaryPath: string;
}

export interface ProviderTestRunModalProps {
  setup: ProviderSetupResponse;
  target: ProviderTestTarget;
  onClose: () => void;
}

function appendLine(setLines: Dispatch<SetStateAction<string[]>>, line: string) {
  setLines((current) => [...current, line]);
}

export function ProviderTestRunModal({ setup, target, onClose }: ProviderTestRunModalProps) {
  const [run, setRun] = useState<ProviderTestRunResponse | null>(null);
  const [lines, setLines] = useState<string[]>([
    `[hub] Requesting an ephemeral ${target.providerLabel} test instance…`,
  ]);
  const [error, setError] = useState('');

  useEffect(() => {
    let cancelled = false;
    void providerSetupMockApi.startTestRun(setup, target.provider, target.modelId).then(
      (response) => {
        if (cancelled) return;
        setRun(response);
        setLines((current) => [
          ...current,
          `[hub] Instance ${response.data.agent_instance_id} created (ephemeral).`,
          `[bridge] Shell ${response.data.shell_session_id} attached on ${setup.data.bridge.label}.`,
        ]);
      },
      (reason) => {
        if (!cancelled) setError(String(reason?.message || reason));
      },
    );
    return () => { cancelled = true; };
  }, [setup, target.modelId, target.provider, target.providerLabel]);

  useEffect(() => {
    if (run?.data.state !== 'detecting') return;
    let cancelled = false;
    const timers = [
      window.setTimeout(() => appendLine(setLines, `$ ${target.binaryPath} --model ${target.modelId}`), 350),
      window.setTimeout(() => appendLine(setLines, `[${target.provider}] Loading credentials and workspace…`), 800),
      window.setTimeout(() => appendLine(setLines, `[agent] Heimdall bootstrap loaded. Starting managed session.`), 1250),
      window.setTimeout(() => {
        appendLine(setLines, `[agent] ham-ctl start-success`);
        void providerSetupMockApi.reportStartSuccess(run).then((response) => {
          if (cancelled) return;
          setRun(response);
          appendLine(setLines, `[hub] start-success received. Instance remains running for validation.`);
        });
      }, 1650),
    ];
    return () => {
      cancelled = true;
      for (const timer of timers) window.clearTimeout(timer);
    };
  }, [run?.data.run_id, run?.data.state, target.binaryPath, target.modelId, target.provider]);

  async function validateAndStop() {
    if (!run || run.data.state !== 'awaiting_validation') return;
    const stopping = structuredClone(run);
    stopping.data.state = 'stopping';
    setRun(stopping);
    appendLine(setLines, '[user] Run marked as validated.');
    appendLine(setLines, `[hub] Stopping ephemeral instance ${run.data.agent_instance_id}…`);
    try {
      const stopped = await providerSetupMockApi.validateAndStopTestRun(stopping);
      setRun(stopped);
      appendLine(setLines, '[bridge] Process exited and temporary instance was removed.');
    } catch (reason: any) {
      setError(String(reason?.message || reason));
    }
  }

  const state = run?.data.state || 'detecting';
  const closable = state === 'stopped' || state === 'failed' || Boolean(error);

  return (
    <Modal
      open
      onOpenChange={(next) => { if (!next && closable) onClose(); }}
      title={`Test ${target.providerLabel} · ${target.modelLabel}`}
      size="lg"
      data-debug-id="provider-test-run-modal"
    >
      <ModalBody className="space-y-4">
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-subtle bg-surface-raised/40 p-3">
          <div>
            <div className="text-sm font-medium text-primary">Ephemeral agent run</div>
            <div className="mt-0.5 text-xs text-muted">
              {run?.data.agent_instance_id || 'Allocating instance…'}
            </div>
          </div>
          {state === 'detecting' ? (
            <StatusPill tone="warning"><span className="inline-flex items-center gap-1.5"><Spinner size="sm" /> Detecting…</span></StatusPill>
          ) : state === 'awaiting_validation' ? (
            <StatusPill tone="success">start-success received</StatusPill>
          ) : state === 'stopping' ? (
            <StatusPill tone="warning">Stopping…</StatusPill>
          ) : state === 'stopped' ? (
            <StatusPill tone="neutral">Stopped</StatusPill>
          ) : (
            <StatusPill tone="danger">Failed</StatusPill>
          )}
        </div>

        <div
          data-debug-id="provider-test-run-output"
          className="min-h-64 overflow-auto rounded-xl border border-subtle bg-black p-4 font-mono text-xs leading-6 text-emerald-300"
          aria-live="polite"
        >
          {lines.map((line, index) => <div key={`${index}-${line}`}>{line}</div>)}
          {!run && !error ? <div className="animate-pulse text-zinc-500">Waiting for bridge…</div> : null}
        </div>

        {state === 'awaiting_validation' ? (
          <div data-debug-id="provider-test-awaiting-validation" className="rounded-xl border border-success/30 bg-success-soft p-3 text-sm text-primary">
            The agent called <code className="font-mono text-success">start-success</code>. Inspect the output, then validate the run. The instance stays alive until you do.
          </div>
        ) : null}
        {state === 'stopped' ? (
          <div data-debug-id="provider-test-stopped" className="rounded-xl border border-subtle bg-surface-raised/40 p-3 text-sm text-muted">
            Validation was session-only. No result was persisted to the Hub or bridge.
          </div>
        ) : null}
        {error ? <div role="alert" className="rounded-xl border border-danger/30 bg-danger-soft p-3 text-sm text-danger">{error}</div> : null}
      </ModalBody>

      <ModalFooter>
        {state === 'awaiting_validation' ? (
          <Button variant="primary" data-debug-id="provider-test-validate-btn" onClick={() => void validateAndStop()}>
            Mark as validated
          </Button>
        ) : closable ? (
          <Button variant="primary" data-debug-id="provider-test-done-btn" onClick={onClose}>Done</Button>
        ) : (
          <Button variant="primary" data-debug-id="provider-test-waiting-btn" disabled>
            {state === 'stopping' ? 'Stopping instance…' : 'Waiting for start-success…'}
          </Button>
        )}
      </ModalFooter>
    </Modal>
  );
}

export default ProviderTestRunModal;
