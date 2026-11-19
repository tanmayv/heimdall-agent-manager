/** Mirrors the provider transport/status contract; old bridges remain PTY-only. */
export type RuntimeTransport = 'pty' | 'acp';
export interface AcpAdapterStatus {
  provider?: string;
  profile?: string;
  runtime_kind?: 'adapter' | 'native';
  installed: boolean;
  version: string | null;
  node_version: string | null;
  state: 'not_checked' | 'missing_node' | 'missing' | 'installing' | 'ready' | 'outdated' | 'error';
  error: string | null;
  checked_at: string | null;
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
const adapterStates = new Set(['not_checked', 'missing_node', 'missing', 'installing', 'ready', 'outdated', 'error']);
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
      ...(adapter.runtime_kind === 'adapter' || adapter.runtime_kind === 'native' ? { runtime_kind: adapter.runtime_kind } : {}),
    } : null,
  };
}
export const acpInstallTerminal = (status: string) => ['succeeded', 'failed', 'cancelled'].includes(status);
export function latestAcpInstall(commands: ProviderSetupCommand[] | undefined, provider: string) {
  return [...(commands || [])].reverse().find((c): c is AcpInstallCommand => c.kind === 'install_acp_adapter' && c.provider === provider);
}
export function acpDisabledReason(supported: boolean | undefined, adapter: AcpAdapterStatus | null): string {
  const runtime = adapter?.runtime_kind === 'native' ? 'runtime' : 'adapter';
  if (!supported) return 'Update this bridge and its PTY host to enable ACP runtime support, then scan providers.';
  if (adapter?.state === 'missing_node') return 'Install Node 22 or newer on the bridge host, then scan providers.';
  if (adapter?.state === 'installing') return `Wait for ${runtime} installation to finish.`;
  if (adapter?.error === 'acp_adapter_unsupported_platform') return 'This ACP runtime is not supported on this platform.';
  if (adapter?.state === 'error') return adapter.error || `The ACP ${runtime} check failed. Check status or install the ${runtime} again.`;
  return '';
}
export function acpAdapterSummary(adapter: AcpAdapterStatus | null): string {
  const state = adapter?.state.replaceAll('_', ' ') || 'not checked';
  const runtime = adapter?.runtime_kind === 'native' ? 'native runtime' : 'adapter';
  return `ACP ${runtime}: ${state} · Version: ${adapter?.version || 'unknown'} · Node: ${adapter?.node_version || 'unknown'}`;
}
