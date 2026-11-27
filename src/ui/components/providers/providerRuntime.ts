import type { AcpAvailability } from '../../api/endpoints/bridgeSupport';

/** Mirrors the provider transport/status contract; old bridges remain PTY-only. */
export type RuntimeTransport = 'pty' | 'acp';
/** The bridge's report. Display only: the Hub's acp_availability is the verdict. */
export interface AcpAdapterStatus {
  provider?: string;
  profile?: string;
  /** 'system' runtimes are user-installed CLIs the bridge only detects and checks. */
  runtime_kind?: 'adapter' | 'system';
  installed: boolean;
  version: string | null;
  node_version: string | null;
  state: 'not_checked' | 'missing_node' | 'missing_npm' | 'missing' | 'installing' | 'ready' | 'outdated' | 'error';
  error: string | null;
  checked_at: string | null;
  /** The bridge's exact command to install a missing/old Node.js or npm on its host. */
  install_command?: string | null;
  /** npm's redacted output from the last failed adapter install. */
  diagnostic?: string | null;
}
export interface ProviderRuntimeFields {
  transports: RuntimeTransport[];
  default_transport: RuntimeTransport;
  transport: RuntimeTransport | null;
  effective_transport: RuntimeTransport;
  acp_adapter: AcpAdapterStatus | null;
}
export interface ProviderSetupCommand {
  command_id: string;
  bridge_id: string;
  provider: string;
  kind: 'install' | 'install_acp_adapter';
  status: string;
  message: string;
  progress_percent: number;
}
export type AcpInstallCommand = ProviderSetupCommand & { kind: 'install_acp_adapter' };
const adapterStates = new Set(['not_checked', 'missing_node', 'missing_npm', 'missing', 'installing', 'ready', 'outdated', 'error']);
const textOrNull = (v: unknown) => typeof v === 'string' && v ? v : null;
export function normalizeProviderRuntime(raw: any): ProviderRuntimeFields {
  const supported: RuntimeTransport[] = Array.isArray(raw?.transports)
    ? [...new Set<RuntimeTransport>(raw.transports.filter((v: unknown) => v === 'pty' || v === 'acp'))] : [];
  const transports: RuntimeTransport[] = supported.length ? supported : ['pty'];
  const fallback = transports.includes('pty') ? 'pty' : transports[0];
  const valid = (v: unknown): v is RuntimeTransport => (v === 'pty' || v === 'acp') && transports.includes(v);
  const default_transport = valid(raw?.default_transport) ? raw.default_transport : fallback;
  const transport = valid(raw?.transport) ? raw.transport : null;
  const adapter = raw?.acp_adapter;
  return {
    transports, default_transport, transport,
    effective_transport: valid(raw?.effective_transport) ? raw.effective_transport : transport || default_transport,
    acp_adapter: adapter && typeof adapter === 'object' && !Array.isArray(adapter) ? {
      installed: adapter.installed === true,
      version: textOrNull(adapter.version), node_version: textOrNull(adapter.node_version),
      state: adapterStates.has(adapter.state) ? adapter.state : 'not_checked',
      error: textOrNull(adapter.error), checked_at: textOrNull(adapter.checked_at),
      ...(typeof adapter.provider === 'string' ? { provider: adapter.provider } : {}),
      ...(typeof adapter.profile === 'string' ? { profile: adapter.profile } : {}),
      ...(adapter.runtime_kind === 'adapter' || adapter.runtime_kind === 'system' ? { runtime_kind: adapter.runtime_kind } : {}),
      ...(textOrNull(adapter.install_command) ? { install_command: adapter.install_command } : {}),
      ...(textOrNull(adapter.diagnostic) ? { diagnostic: adapter.diagnostic } : {}),
    } : null,
  };
}
export const acpInstallTerminal = (status: string) => ['succeeded', 'failed', 'cancelled'].includes(status);
export function latestAcpInstall(commands: ProviderSetupCommand[] | undefined, provider: string) {
  return [...(commands || [])].reverse().find((c): c is AcpInstallCommand => c.kind === 'install_acp_adapter' && c.provider === provider);
}
export const acpSystemRuntime = (adapter: AcpAdapterStatus | null) => adapter?.runtime_kind === 'system';
/** No verdict yet (status loading, or a Hub that predates it) reads as not checked. */
export const ACP_NOT_CHECKED: AcpAvailability = { available: false, reason: 'not_checked', fix: 'check_now' };

/**
 * Why the ACP option is disabled, from the Hub's verdict only (`acp_availability`,
 * computed by classify_acp_availability from the bridge's report). The text is the
 * bridge's own message where it has one; nothing here re-derives readiness.
 * '' keeps ACP selectable: selecting it starts the tracked install or Re-check.
 */
export function acpDisabledReason(availability: AcpAvailability | null | undefined, adapter: AcpAdapterStatus | null): string {
  const verdict = availability || ACP_NOT_CHECKED;
  const system = acpSystemRuntime(adapter);
  switch (verdict.reason) {
    case 'ready':
    case 'not_checked':
      return '';
    case 'unsupported_bridge':
      return 'Update this bridge and its PTY host to enable ACP runtime support, then scan providers.';
    case 'no_recipe':
      return 'This provider has no ACP runtime.';
    case 'installing':
      return system ? 'Wait for the CLI check to finish.' : 'Wait for adapter installation to finish.';
    case 'adapter_missing_node':
    case 'adapter_missing_npm':
      return adapter?.error || (system ? 'The CLI check failed. Re-check after fixing it on the bridge host.' : 'Install Node.js and npm on the bridge host, then check again.');
    case 'adapter_missing':
      // Heimdall never installs a system CLI; an adapter installs on selection.
      return system ? adapter?.error || 'Install the CLI on the bridge host (or set the profile binary), then Re-check.' : '';
    case 'adapter_outdated':
      return system ? adapter?.error || 'Upgrade the CLI on the bridge host, then Re-check.' : '';
    case 'adapter_error':
    default:
      if (adapter?.error === 'acp_adapter_unsupported_platform') return 'This ACP runtime is not supported on this platform.';
      return adapter?.error || (system ? 'The CLI check failed. Re-check after fixing it on the bridge host.' : 'The ACP adapter check failed. Check status or install the adapter again.');
  }
}
export function acpAdapterSummary(adapter: AcpAdapterStatus | null): string {
  const state = adapter?.state.replaceAll('_', ' ') || 'not checked';
  if (acpSystemRuntime(adapter)) {
    const runtime = adapter?.provider === 'codex' ? 'Codex app-server runtime' : 'ACP system CLI';
    return `${runtime}: ${state} · Version: ${adapter?.version || 'unknown'}`;
  }
  return `ACP adapter: ${state} · Version: ${adapter?.version || 'unknown'} · Node: ${adapter?.node_version || 'unknown'}`;
}
