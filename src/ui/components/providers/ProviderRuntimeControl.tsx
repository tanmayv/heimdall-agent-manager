import { useEffect, useRef, useState } from 'react';
import { Button, Text } from '@ui';
import { apiErrorText } from '../../api/cookieFetch';
import { providerSetupApi, type BridgeProviderStatus, type ProviderSetupResponse } from './providerSetupApi';
import { ACP_NOT_CHECKED, acpAdapterSummary, acpDisabledReason, acpInstallTerminal, acpSystemRuntime, latestAcpInstall, type AcpInstallCommand, type RuntimeTransport } from './providerRuntime';

export const ACP_INSTALL_WAIT_MS = 150_000;

/** Debug id suffix of one profile's selector: the provider id for its default profile. */
export const runtimeProfileKey = (row: BridgeProviderStatus) =>
  !row.profile_id || row.profile_id === row.provider ? row.provider : `${row.provider}-${row.profile_id}`;

/**
 * The provider's runtime on one bridge. The transport is chosen per profile (G6):
 * one selector per row in `profiles` (default: just `status`; none for a profile
 * not saved yet), each showing the Hub's resolved value for that profile.
 * `status` is the provider's default-profile row; the ACP adapter install/check
 * block is provider-wide and shown once.
 */
export default function ProviderRuntimeControl({ setup, status, profiles, disabledReason = '', onChange }: {
  setup: ProviderSetupResponse;
  status: BridgeProviderStatus;
  profiles?: BridgeProviderStatus[];
  disabledReason?: string;
  onChange: (setup: ProviderSetupResponse) => void;
}) {
  const rows = profiles ?? [status];
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
      // Re-detect on the bridge (Node.js, npm, CLI version) rather than re-read a
      // possibly stale row, so a newly installed tool shows up without a restart.
      onChangeRef.current(await providerSetupApi.redetect(setup, provider));
      // Checking is an explicit retry of the bounded wait, not another install.
      setTimedOut(false);
    } catch (e) { setError(apiErrorText(e)); }
    finally { setBusy(false); }
  }

  async function change(row: BridgeProviderStatus, transport: RuntimeTransport | null) {
    setBusy(true);
    setError('');
    try {
      onChangeRef.current(await providerSetupApi.setTransport(setup, provider, transport, row.profile_id || provider));
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
  // The Hub's verdict decides; the bridge's report only supplies display text.
  const verdict = status.acp_availability || ACP_NOT_CHECKED;
  const acpReason = acpDisabledReason(verdict, status.acp_adapter);
  // Each profile has its own verdict: a profile can be unable to run ACP while the install is ready.
  const rowAcpReason = (row: BridgeProviderStatus) => acpDisabledReason(row.acp_availability || ACP_NOT_CHECKED, row.acp_adapter);
  const multiple = rows.length > 1;
  // A missing host prerequisite is fixed by the user; the action re-detects it.
  const prerequisite = verdict.reason === 'adapter_missing_node' || verdict.reason === 'adapter_missing_npm';
  const adapterError = status.acp_adapter?.error || '';
  const installCommand = status.acp_adapter?.install_command || '';
  const installable = status.transports.includes('acp') && (verdict.fix === 'install_adapter' || verdict.fix === 'check_now');
  const failed = command?.status === 'failed' || command?.status === 'cancelled';
  // Descriptor data (Hub) or the bridge report, never the provider id (G9).
  const system = status.acp_runtime_kind === 'system' || acpSystemRuntime(status.acp_adapter);
  return (
    <div className="min-w-0 space-y-2 rounded-lg border border-subtle p-3">
      {rows.map((row) => {
        const key = runtimeProfileKey(row);
        const rowReason = rowAcpReason(row);
        const name = multiple ? `${row.label || row.profile_id || row.display_name}` : status.display_name;
        return <div key={key} className="flex flex-wrap items-center gap-3">
          <label className="flex min-w-0 flex-wrap items-center gap-2" title={reason || undefined}>
            <span className="text-sm font-medium">{multiple ? `${name} runtime` : 'Runtime'}</span>
            <select aria-label={`${name} runtime`} title={reason || undefined}
              data-debug-id={`providers-runtime-select-${key}`}
              value={row.effective_transport ?? ''} disabled={Boolean(reason) || busy || (active && !timedOut)}
              onChange={(e) => void change(row, e.target.value as RuntimeTransport)}
              className="min-h-10 rounded-md border border-subtle bg-surface px-3 text-sm text-primary disabled:opacity-50">
              {/* No resolved value from the Hub: show that, never a guess. */}
              {row.effective_transport === null ? <option value="" disabled>Unknown</option> : null}
              {row.transports.map((transport) => <option key={transport} value={transport}
                disabled={transport === 'acp' && Boolean(rowReason)} title={transport === 'acp' ? rowReason : undefined}>{transport === 'acp' && provider === 'codex' ? 'ACP (Codex app-server)' : transport.toUpperCase()}</option>)}
            </select>
          </label>
          <Button size="sm" variant="secondary" data-debug-id={`providers-runtime-reset-${key}`}
            title={disabledReason || `Catalog default: ${row.default_transport.toUpperCase()}`}
            disabled={Boolean(disabledReason) || busy || row.transport === null}
            onClick={() => void change(row, null)}>Reset to catalog default</Button>
          {multiple && row.acp_availability && row.acp_availability.reason !== verdict.reason && rowReason
            ? <p data-debug-id={`providers-runtime-profile-acp-${key}`} className="w-full text-xs text-muted">{rowReason}</p> : null}
        </div>;
      })}
      <div className="flex flex-wrap items-center gap-3">
        {installable ? <Button size="sm" variant="secondary" data-debug-id={`providers-acp-install-${provider}`}
          title={disabledReason || acpReason || undefined}
          disabled={Boolean(disabledReason) || !setup.acp_runtime_supported || busy || active}
          onClick={() => void install()}>{system || prerequisite ? 'Re-check' : 'Install adapter'}</Button> : null}
        {status.transports.includes('acp') ? <Button size="sm" variant="ghost" data-debug-id={`providers-acp-check-${provider}`}
          disabled={busy} onClick={() => void checkStatus()}>Check status</Button> : null}
      </div>
      <Text role="caption" tone="muted">Chosen per {status.display_name} profile on this bridge; the adapter is shared. Applies on the next launch; existing instances keep their runtime unless they override it.</Text>
      {/* The bridge's own error is shown once, in the status block below. */}
      {reason || (status.transports.includes('acp') && acpReason && acpReason !== adapterError) ? <p className="text-xs text-muted">{reason || acpReason}</p> : null}
      {status.transports.includes('acp') ? <div data-debug-id={`providers-acp-status-${provider}`} role="status" className="space-y-1 break-words text-xs text-muted">
        <p>{acpAdapterSummary(status.acp_adapter)}</p>
        {/* The install command appears once: inline when the message ends with it. */}
        {adapterError ? <p className="text-danger">{installCommand && adapterError.endsWith(installCommand)
          ? <>{adapterError.slice(0, -installCommand.length)}<code data-debug-id={`providers-acp-install-command-${provider}`} className="break-all">{installCommand}</code></>
          : adapterError}</p> : null}
        {installCommand && !adapterError.endsWith(installCommand) ? <p>Run on the bridge host: <code data-debug-id={`providers-acp-install-command-${provider}`} className="break-all">{installCommand}</code></p> : null}
        {status.acp_adapter?.diagnostic ? <pre data-debug-id={`providers-acp-diagnostic-${provider}`} className="max-h-40 overflow-auto whitespace-pre-wrap rounded bg-surface-raised p-2 text-xs">{status.acp_adapter.diagnostic}</pre> : null}
        {command ? <p className={failed ? 'text-danger' : ''}>{system ? 'Check' : 'Installation'}: {command.status}{command.message ? ` · ${command.message}` : ''}</p> : null}
        {active && !timedOut ? <progress aria-label={system ? 'ACP CLI check progress' : 'ACP adapter installation progress'} max={100} value={Math.max(0, Math.min(100, command?.progress_percent || 0))} /> : null}
        {timedOut ? <p role="alert">{system ? 'The CLI check' : 'Installation status'} did not finish within 150 seconds. Use Check status to refresh; the bridge may still be {system ? 'checking' : 'installing'}.</p> : null}
        {command?.status === 'succeeded' && status.effective_transport !== 'acp' && !system ? <p>Adapter installed. Select ACP to use it on the next launch.</p> : null}
      </div> : null}
      {error ? <p role="alert" className="break-words text-xs text-danger">{error}</p> : null}
    </div>
  );
}
