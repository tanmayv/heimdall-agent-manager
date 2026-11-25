import { useEffect, useRef, useState } from 'react';
import { Button, Text } from '@ui';
import { apiErrorText } from '../../api/cookieFetch';
import { providerSetupApi, type BridgeProviderStatus, type ProviderSetupResponse } from './providerSetupApi';
import { acpAdapterSummary, acpDisabledReason, acpInstallTerminal, acpSystemRuntime, latestAcpInstall, type AcpInstallCommand, type RuntimeTransport } from './providerRuntime';

export const ACP_INSTALL_WAIT_MS = 150_000;

/** One control for the provider, never a profile override. */
export default function ProviderRuntimeControl({ setup, status, disabledReason = '', onChange }: {
  setup: ProviderSetupResponse;
  status: BridgeProviderStatus;
  disabledReason?: string;
  onChange: (setup: ProviderSetupResponse) => void;
}) {
  const provider = status.provider;
  const bridgeId = setup.bridge.bridge_id;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [timedOut, setTimedOut] = useState(false);
  const [submitted, setSubmitted] = useState<AcpInstallCommand | null>(null);
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;
  const latest = latestAcpInstall(setup.extension_commands, provider);
  const command = submitted
    ? setup.extension_commands?.find((c) => c.command_id === submitted.command_id) || submitted
    : latest;
  const active = Boolean(command && !acpInstallTerminal(command.status));
  const commandId = active ? command!.command_id : '';

  useEffect(() => {
    if (submitted && setup.extension_commands?.some((c) => c.command_id === submitted.command_id)) setSubmitted(null);
  }, [submitted, setup.extension_commands]);

  useEffect(() => {
    setTimedOut(false);
  }, [commandId]);

  // Poll only an active tracked command, including one recovered after navigation.
  // The independent deadline also stops waiting if a status request never returns.
  useEffect(() => {
    if (!commandId || timedOut) return;
    let cancelled = false;
    let poll: ReturnType<typeof setTimeout>;
    const deadline = setTimeout(() => { setTimedOut(true); }, ACP_INSTALL_WAIT_MS);
    const check = async () => {
      try {
        const result = await providerSetupApi.get(bridgeId, true, true);
        if (!cancelled) {
          onChangeRef.current(result);
          setError('');
        }
      } catch (e) {
        if (!cancelled) setError('Could not refresh adapter installation status: ' + apiErrorText(e));
      }
      if (!cancelled) poll = setTimeout(() => void check(), 1000);
    };
    void check();
    return () => { cancelled = true; clearTimeout(deadline); clearTimeout(poll); };
  }, [bridgeId, commandId, timedOut]);

  async function checkStatus() {
    setBusy(true);
    setError('');
    try {
      onChangeRef.current(await providerSetupApi.get(bridgeId, true, true));
      // Checking is an explicit retry of the bounded wait, not another install.
      setTimedOut(false);
    } catch (e) { setError(apiErrorText(e)); }
    finally { setBusy(false); }
  }

  async function change(transport: RuntimeTransport | null) {
    setBusy(true);
    setError('');
    try {
      onChangeRef.current(await providerSetupApi.setTransport(setup, provider, transport));
    } catch (e) {
      setError(apiErrorText(e));
      // Selecting ACP can start an automatic install without saving the setting.
      try { onChangeRef.current(await providerSetupApi.get(bridgeId, true, true)); } catch { /* keep the original error */ }
    } finally { setBusy(false); }
  }

  async function install() {
    setBusy(true);
    setError('');
    try {
      const result = await providerSetupApi.installAdapter(setup, provider);
      setSubmitted({ command_id: result.command_id, bridge_id: bridgeId, provider,
        kind: 'install_acp_adapter', status: 'queued', message: '', progress_percent: 0 });
      setTimedOut(false);
    } catch (e) { setError(apiErrorText(e)); }
    finally { setBusy(false); }
  }

  const singleReason = status.transports.length === 1 ? `This provider supports only ${status.transports[0].toUpperCase()}.` : '';
  const reason = disabledReason || singleReason;
  const acpReason = acpDisabledReason(setup.acp_runtime_supported, status.acp_adapter);
  const installable = status.transports.includes('acp') && (!status.acp_adapter || ['missing', 'outdated', 'error', 'not_checked'].includes(status.acp_adapter.state));
  const failed = command?.status === 'failed' || command?.status === 'cancelled';
  const system = provider === 'opencode' || acpSystemRuntime(status.acp_adapter);
  return (
    <div className="min-w-0 space-y-2 rounded-lg border border-subtle p-3">
      <div className="flex flex-wrap items-center gap-3">
        <label className="flex min-w-0 flex-wrap items-center gap-2" title={reason || undefined}>
          <span className="text-sm font-medium">Runtime</span>
          <select aria-label={`${status.display_name} runtime`} title={reason || undefined}
            data-debug-id={`providers-runtime-select-${provider}`}
            value={status.effective_transport} disabled={Boolean(reason) || busy || (active && !timedOut)}
            onChange={(e) => void change(e.target.value as RuntimeTransport)}
            className="min-h-10 rounded-md border border-subtle bg-surface px-3 text-sm text-primary disabled:opacity-50">
            {status.transports.map((transport) => <option key={transport} value={transport}
              disabled={transport === 'acp' && Boolean(acpReason)} title={transport === 'acp' ? acpReason : undefined}>{transport === 'acp' && provider === 'codex' ? 'ACP (Codex app-server)' : transport.toUpperCase()}</option>)}
          </select>
        </label>
        <Button size="sm" variant="secondary" data-debug-id={`providers-runtime-reset-${provider}`}
          title={disabledReason || `Catalog default: ${status.default_transport.toUpperCase()}`}
          disabled={Boolean(disabledReason) || busy || status.transport === null}
          onClick={() => void change(null)}>Reset to catalog default</Button>
        {installable ? <Button size="sm" variant="secondary" data-debug-id={`providers-acp-install-${provider}`}
          title={disabledReason || acpReason || undefined}
          disabled={Boolean(disabledReason) || !setup.acp_runtime_supported || busy || active}
          onClick={() => void install()}>{system ? 'Re-check' : `Install ${status.acp_adapter?.runtime_kind === 'native' ? 'runtime' : 'adapter'}`}</Button> : null}
        {status.transports.includes('acp') ? <Button size="sm" variant="ghost" data-debug-id={`providers-acp-check-${provider}`}
          disabled={busy} onClick={() => void checkStatus()}>Check status</Button> : null}
      </div>
      <Text role="caption" tone="muted">Shared by all {status.display_name} profiles on this bridge. Applies on the next launch; existing instances keep their runtime.</Text>
      {reason || (status.transports.includes('acp') && acpReason) ? <p className="text-xs text-muted">{reason || acpReason}</p> : null}
      {status.transports.includes('acp') ? <div data-debug-id={`providers-acp-status-${provider}`} role="status" className="space-y-1 break-words text-xs text-muted">
        <p>{acpAdapterSummary(status.acp_adapter)}</p>
        {status.acp_adapter?.error ? <p className="text-danger">{status.acp_adapter.error}</p> : null}
        {command ? <p className={failed ? 'text-danger' : ''}>{system ? 'Check' : 'Installation'}: {command.status}{command.message ? ` · ${command.message}` : ''}</p> : null}
        {active && !timedOut ? <progress aria-label={system ? 'ACP CLI check progress' : 'ACP adapter installation progress'} max={100} value={Math.max(0, Math.min(100, command?.progress_percent || 0))} /> : null}
        {timedOut ? <p role="alert">{system ? 'The CLI check' : 'Installation status'} did not finish within 150 seconds. Use Check status to refresh; the bridge may still be {system ? 'checking' : 'installing'}.</p> : null}
        {command?.status === 'succeeded' && status.effective_transport !== 'acp' && !system ? <p>{status.acp_adapter?.runtime_kind === 'native' ? 'Runtime' : 'Adapter'} installed. Select ACP to use it on the next launch.</p> : null}
      </div> : null}
      {error ? <p role="alert" className="break-words text-xs text-danger">{error}</p> : null}
    </div>
  );
}
