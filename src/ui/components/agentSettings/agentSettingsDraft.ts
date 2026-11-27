/**
 * agentSettingsDraft — the pure draft model behind the Agent settings panel
 * (sections 2-5: Runs on, Model, Connection, Permissions). See DESIGN.md.
 *
 * Nothing in the panel applies on click: every control edits a DRAFT `AgentConfig`.
 * This module holds every rule about that draft, with no React and no fetch, so each
 * rule is unit-testable (tests/ui_agent_settings_draft_test.ts):
 *
 *   - `reduceAgentDraft`: the reducer (bridge / provider / model / transport / bypass /
 *     reset). A bridge change whose provider is not installed there switches to the
 *     first installed provider and its first model; a provider change resets the model
 *     to that provider's first model.
 *   - `reconcileDraftProviders`: the same bridge fallback, applied once the picked
 *     bridge's provider status arrives (it is fetched lazily per bridge).
 *   - `draftDiff`: `{field, from, to}` per changed field, for the staged-changes footer.
 *   - `applyBlockedReason`: why Apply must stay disabled (ACP selected but unavailable).
 *   - `bridgeRowsView`, `providerOptionsFromStatus`, `modelOptionLabel`,
 *     `permissionsDetail`: view models for the sections.
 */
import type { AcpAvailability } from '../../api/endpoints/bridgeSupport';

export type RuntimeTransport = 'pty' | 'acp';

export interface AgentConfig {
  bridgeId: string;
  /** Provider driver (claude, codex, …). */
  provider: string;
  /** Profile id (equals `provider` for the default profile). */
  providerProfile: string;
  model: string;
  transport: RuntimeTransport;
  /** Bypass permissions (instance permission_mode yolo). */
  bypass: boolean;
}

/** One provider (profile) row of the draft bridge's provider status. */
export interface ProviderOption {
  /** Profile id, or the provider id for the default profile. */
  id: string;
  provider: string;
  label: string;
  /** Present, enabled and launchable on this bridge. */
  installed: boolean;
  /** Present on the bridge but turned off there. */
  disabledOnBridge: boolean;
  /** "2.1.0" ('' when unknown). */
  version: string;
  /** Launchable model ids, in the bridge's order. */
  models: string[];
  /** The hub's ACP verdict for this bridge + provider (null: older hub). */
  acp: AcpAvailability | null;
  /** ISO time the bridge last checked this provider. */
  checkedAt: string | null;
}

// ---------------------------------------------------------------- reducer

export type AgentDraftAction =
  /** `providers`: the new bridge's provider options, or null while they load. */
  | { type: 'bridge'; bridgeId: string; providers: ProviderOption[] | null }
  | { type: 'provider'; id: string; providers: ProviderOption[] }
  | { type: 'model'; model: string }
  | { type: 'transport'; transport: RuntimeTransport }
  | { type: 'bypass'; bypass: boolean }
  | { type: 'reset'; config: AgentConfig };

function providerKey(config: Pick<AgentConfig, 'provider' | 'providerProfile'>): string {
  return config.providerProfile || config.provider;
}

/**
 * Keep the draft's provider when it is installed on the bridge (and its model when
 * that provider still offers it), else switch to the first installed provider and
 * its first model. Unchanged when the bridge has no installed provider at all, so the
 * section can say so instead of silently clearing the choice.
 */
export function reconcileDraftProviders(draft: AgentConfig, providers: ProviderOption[]): AgentConfig {
  const installed = providers.filter((p) => p.installed);
  const current = installed.find((p) => p.id === providerKey(draft));
  if (current) {
    if (!draft.model || current.models.length === 0 || current.models.includes(draft.model)) return draft;
    return { ...draft, model: current.models[0] };
  }
  const first = installed[0];
  if (!first) return draft;
  return { ...draft, provider: first.provider, providerProfile: first.id, model: first.models[0] || '' };
}

export function reduceAgentDraft(draft: AgentConfig, action: AgentDraftAction): AgentConfig {
  switch (action.type) {
    case 'bridge': {
      if (action.bridgeId === draft.bridgeId) return draft;
      const moved = { ...draft, bridgeId: action.bridgeId };
      return action.providers ? reconcileDraftProviders(moved, action.providers) : moved;
    }
    case 'provider': {
      if (action.id === providerKey(draft)) return draft;
      const option = action.providers.find((p) => p.id === action.id);
      if (!option || !option.installed) return draft;
      return { ...draft, provider: option.provider, providerProfile: option.id, model: option.models[0] || '' };
    }
    case 'model':
      return action.model === draft.model ? draft : { ...draft, model: action.model };
    case 'transport':
      return action.transport === draft.transport ? draft : { ...draft, transport: action.transport };
    case 'bypass':
      return action.bypass === draft.bypass ? draft : { ...draft, bypass: action.bypass };
    case 'reset':
      return action.config;
    default:
      return draft;
  }
}

// ---------------------------------------------------------------- diff

export type DraftField = 'bridge' | 'provider' | 'model' | 'connection' | 'bypass';

export interface DraftChange {
  field: DraftField;
  /** Display label of the field: "Bridge", "Provider", "Model", "Connection", "Bypass". */
  label: string;
  from: string;
  to: string;
}

export interface DraftLabels {
  bridgeLabel?: (bridgeId: string) => string;
  providerLabel?: (config: AgentConfig) => string;
}

export const DRAFT_FIELD_LABELS: Record<DraftField, string> = {
  bridge: 'Bridge',
  provider: 'Provider',
  model: 'Model',
  connection: 'Connection',
  bypass: 'Bypass',
};

export function transportLabel(transport: RuntimeTransport): 'PTY' | 'ACP' {
  return transport === 'acp' ? 'ACP' : 'PTY';
}

/** One entry per changed field, in panel order (bridge, provider, model, connection, bypass). */
export function draftDiff(current: AgentConfig, draft: AgentConfig, labels: DraftLabels = {}): DraftChange[] {
  const bridgeName = labels.bridgeLabel || ((id: string) => id);
  const providerName = labels.providerLabel || ((c: AgentConfig) => providerKey(c));
  const changes: DraftChange[] = [];
  const push = (field: DraftField, from: string, to: string) => changes.push({ field, label: DRAFT_FIELD_LABELS[field], from, to });
  if (draft.bridgeId !== current.bridgeId) push('bridge', bridgeName(current.bridgeId), bridgeName(draft.bridgeId));
  if (providerKey(draft) !== providerKey(current)) push('provider', providerName(current), providerName(draft));
  if (draft.model !== current.model) push('model', current.model, draft.model);
  if (draft.transport !== current.transport) push('connection', transportLabel(current.transport), transportLabel(draft.transport));
  if (draft.bypass !== current.bypass) push('bypass', current.bypass ? 'on' : 'off', draft.bypass ? 'on' : 'off');
  return changes;
}

// ---------------------------------------------------------------- apply gate

export type ApplyBlockedCode = 'acp_unavailable';

export interface ApplyBlockedReason {
  code: ApplyBlockedCode;
  /** Footer copy. */
  message: string;
}

export const ACP_APPLY_BLOCKED_MESSAGE = 'Fix the connection above before applying.';

/**
 * Why Apply must stay disabled, from the draft alone (null: nothing here blocks it).
 * ACP is blocked unless the hub's verdict for the DRAFT bridge + provider says it is
 * available; a missing verdict (still loading, or an older hub) also blocks, because
 * the hub would refuse the launch.
 */
export function applyBlockedReason(draft: AgentConfig, providers: ProviderOption[] | null): ApplyBlockedReason | null {
  if (draft.transport !== 'acp') return null;
  const option = (providers || []).find((p) => p.id === providerKey(draft));
  if (option?.acp?.available) return null;
  return { code: 'acp_unavailable', message: ACP_APPLY_BLOCKED_MESSAGE };
}

// ---------------------------------------------------------------- view models

/** "2.1.0" from version_text such as "2.1.0", "v2.1.0" or "2.1.0 (Claude Code)". */
export function providerVersion(versionText: string): string {
  const text = String(versionText || '').trim();
  const match = text.match(/v?(\d+(?:\.\d+)+(?:[-+][\w.]+)?)/);
  return match ? match[1] : text;
}

/**
 * The draft bridge's provider status rows (GET /bridges/{id}/provider-status) as
 * provider options. Rows the catalog retired are left out; every other row is
 * listed, installed or not, so the section can show why it cannot be picked.
 */
export function providerOptionsFromStatus(status: any): ProviderOption[] {
  const rows: any[] = Array.isArray(status?.providers) ? status.providers : [];
  return rows
    .filter((row) => row?.provider && (!row.catalog_state || row.catalog_state === 'active'))
    .map((row) => {
      const present = row.state === 'present';
      return {
        id: String(row.profile_id || row.provider),
        provider: String(row.provider),
        label: String(row.label || row.display_name || row.provider),
        installed: present && row.enabled === true,
        disabledOnBridge: present && row.enabled !== true,
        version: providerVersion(String(row.version_text || '')),
        models: (Array.isArray(row.models) ? row.models : [])
          .filter((m: any) => !m?.state || m.state === 'active')
          .map((m: any) => String(m?.model_id || ''))
          .filter(Boolean),
        acp: row.acp_availability ?? null,
        checkedAt: row.checked_at ? String(row.checked_at) : null,
      };
    });
}

/** The provider row's status line. */
export function providerStatusLine(option: ProviderOption, bridgeLabel: string): string {
  if (option.installed) return option.version ? `Installed · v${option.version}` : 'Installed';
  if (option.disabledOnBridge) return `Not enabled on ${bridgeLabel}`;
  return `Not installed on ${bridgeLabel}`;
}

export function modelOptionLabel(model: string): string {
  return model === 'default' ? 'default (provider picks)' : model;
}

/** Most recent `checked_at` among the options (null when none reports one). */
export function lastCheckedAt(providers: ProviderOption[]): string | null {
  let best: string | null = null;
  let bestMs = -Infinity;
  for (const p of providers) {
    const ms = Date.parse(String(p.checkedAt || ''));
    if (Number.isFinite(ms) && ms > bestMs) { bestMs = ms; best = p.checkedAt; }
  }
  return best;
}

export type BridgeRowStatus = 'connected' | 'offline' | 'no_folder';

export interface BridgeRowView {
  bridgeId: string;
  label: string;
  current: boolean;
  status: BridgeRowStatus;
  /** "Connected · Fedora Atomic" | "Offline" | "No folder for this project". */
  statusText: string;
  /** The project's folder on this bridge ('' when none). */
  folder: string;
  disabled: boolean;
}

export interface BridgeRowsView {
  rows: BridgeRowView[];
  connected: number;
  total: number;
  /** "3 of 5 connected". */
  header: string;
}

export interface BridgeRowsInput {
  bridges: any[];
  currentBridgeId: string;
  /** The agent's project ('' when it has none: every bridge can host it). */
  projectId: string;
  /** GET /projects/{id} → bridge_paths. */
  bridgePaths: Array<{ bridge_id?: string; bridgeId?: string; path?: string }>;
  /** The project's default folder, used by bridges with no path of their own. */
  defaultPath?: string;
  /** instance.project_path: the folder the agent runs in now (current bridge). */
  currentFolder?: string;
}

function rowBridgeId(bridge: any): string {
  return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
}

function bridgeRevoked(bridge: any): boolean {
  return Boolean(bridge?.revoked_at) || String(bridge?.status || '').toLowerCase() === 'revoked';
}

export function bridgeConnected(bridge: any): boolean {
  return !bridge?.plan_disabled_at && String(bridge?.status || '').toLowerCase() === 'online';
}

/** The owned, non-revoked bridges as rows: connected, offline, or without the project's folder. */
export function bridgeRowsView(input: BridgeRowsInput): BridgeRowsView {
  const paths = new Map<string, string>();
  for (const entry of input.bridgePaths || []) {
    const id = String(entry?.bridge_id || entry?.bridgeId || '');
    if (id && entry?.path) paths.set(id, String(entry.path));
  }
  const rows = (input.bridges || []).filter((b) => rowBridgeId(b) && !bridgeRevoked(b)).map((bridge): BridgeRowView => {
    const bridgeId = rowBridgeId(bridge);
    const current = bridgeId === input.currentBridgeId;
    const folder = (current && input.currentFolder) || paths.get(bridgeId) || input.defaultPath || '';
    const connected = bridgeConnected(bridge);
    const os = String(bridge?.machine_os || bridge?.os || '').trim();
    const status: BridgeRowStatus = !connected ? 'offline' : input.projectId && !folder ? 'no_folder' : 'connected';
    return {
      bridgeId,
      label: String(bridge?.label || bridge?.machine_hostname || bridgeId),
      current,
      status,
      statusText: status === 'offline' ? 'Offline' : status === 'no_folder' ? 'No folder for this project' : os ? `Connected · ${os}` : 'Connected',
      folder,
      disabled: status !== 'connected',
    };
  });
  const connected = rows.filter((r) => r.status !== 'offline').length;
  return { rows, connected, total: rows.length, header: `${connected} of ${rows.length} connected` };
}

/** Permissions card: the second line under the description, from the DRAFT. */
export function permissionsDetail(draft: Pick<AgentConfig, 'bypass' | 'transport'>, providerLabel: string): string {
  if (draft.bypass) return 'Turn it off to approve each tool call yourself.';
  if (draft.transport === 'acp') return 'Approvals appear in the conversation as they happen.';
  return `In PTY, approvals show in the terminal. Install the ${providerLabel} extension to approve from chat.`;
}

export const PERMISSIONS_DESCRIPTION =
  "The agent runs tools without asking. New agents use the default set in the agent's settings.";
