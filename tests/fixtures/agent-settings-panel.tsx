// Browser-only fixture: the real AgentChatPane with the Agent settings panel against an
// in-memory hub. ?state=running (mid-turn)|idle|stopped|restarting|waiting|still_waiting,
// ?acp=<acp_availability reason> (claude's verdict on every bridge; default ready).
// POST /reconfigurations is accepted in memory (the agent then shows Restarting).
// No request leaves the page.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { heimdallApi } from '../../src/ui/api/heimdallApi';
import { AgentChatPane } from '../../src/ui/components/workbench/AgentChatPane';
import { ShortcutProvider } from '../../src/ui/services/shortcuts/ShortcutContext';
import { keyringInstalled } from '../../src/ui/store/vaultSlice';
import { importKeyring, serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring';
import { setActiveVaultKey } from '../../src/ui/utils/vaultCrypto';
import '../../src/ui/styles.css';

const params = new URLSearchParams(location.search);
const state = params.get('state') || 'running';
const acpReason = params.get('acp') || 'ready';
const ACP_FIX: Record<string, string | null> = { ready: null, no_recipe: null, unsupported_bridge: 'update_bridge', adapter_missing: 'install_adapter',
  adapter_outdated: 'install_adapter', adapter_missing_node: 'install_adapter', adapter_error: 'install_adapter', installing: null, not_checked: 'check_now' };
const now = Date.now();
const startedAt = new Date(now - (2 * 60 + 14) * 60000).toISOString();

const modules = import.meta.glob('../../src/ui/store/*Slice.ts', { eager: true }) as Record<string, any>;
const slice = (file: string) => modules[`../../src/ui/store/${file}.ts`].default;
const reducers: any = {
  composerContext: slice('composerContextSlice'), chat: slice('chatSlice'), vault: slice('vaultSlice'), tasks: slice('taskSlice'),
  memory: slice('memorySlice'), projects: slice('projectSlice'), home: slice('homeSlice'), chainView: slice('chainViewSlice'),
  attention: slice('attentionSlice'), cards: slice('cardsSlice'), toasts: slice('toastSlice'), notifications: slice('notificationsSlice'),
  workspaceLayout: slice('workspaceLayoutSlice'), auxPanes: slice('auxPanesSlice'), workspaceChrome: slice('workspaceChromeSlice'),
  inputPreferences: slice('inputPreferencesSlice'), searchTitle: slice('searchTitleSlice'), agentActivity: slice('agentActivitySlice'),
  toolActivity: slice('toolActivitySlice'), deviceVault: slice('deviceVaultSlice'), shells: slice('shellSlice'), theme: slice('themeSlice'),
};
const store = configureStore({ reducer: { ...reducers, [heimdallApi.reducerPath]: heimdallApi.reducer },
  middleware: (g) => g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware) });

setActiveVaultKey(await importKeyring(serializeKeyringBytes({ userId: 'usr_test', vaultId: '7e57000000000001',
  currentEpoch: 1, entries: [{ epoch: 1, key: new Uint8Array(32).fill(17) }] })));
store.dispatch(keyringInstalled({ currentEpoch: 1 }));

const at = (min: number) => new Date(now - min * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const messages = [
  { message_id: 'm1', conversation_id: 'conv', direction: 'user_to_agent', body: 'Release v0.5.86 from main with only the auto-update fix.', created_at: at(20), read_at: at(20), message_type: 'text', message_status: 'complete', metadata: {} },
  { message_id: 'm2', conversation_id: 'conv', direction: 'agent_to_user', body: '**T16e: Release v0.5.86 from main** is now in progress.\n\n- Cherry-pick `bad4763d` + `538c840b` onto fresh `origin/main`.\n- Test Runner PASS → bump to **v0.5.86** → push `main` + tag.\n- **Stops before promotion.** I\'ll ask you before it goes out to bridges.', created_at: at(18), message_type: 'text', message_status: 'complete', metadata: {}, sender_agent_instance_id: 'inst_coord' },
];
const instance = {
  agent_instance_id: 'inst_coord', agent_id: 'agt_coord', provider: 'claude', model: 'default', bridge_id: 'brg_riverwood',
  project_id: 'prj_heimdall', project_path: '/var/home/tanmay/heimdall-agent-manager', runtime_transport: 'pty', launch_epoch: 'ep1', configuration_revision: 7,
  runtime_status: state === 'stopped' ? 'stopped' : 'running',
  activity_status: ['running', 'waiting', 'still_waiting'].includes(state) ? 'working' : 'idle',
  started_at: state === 'stopped' ? '' : startedAt, stop_reason: state === 'stopped' ? 'user_stop' : '', display_name: 'coordinator #41',
};
const operation = (phase: string, extra: Record<string, unknown> = {}) => ({ operation_id: 'op1', agent_instance_id: 'inst_coord', idempotency_key: 'k',
  phase, revision: 3, source: {}, destination: {}, source_stopped: phase === 'launching', destination_committed: phase === 'launching',
  failure_code: '', failure_message: '', ...extra });
let operations: any[] = state === 'restarting' ? [operation('launching')]
  : state === 'waiting' ? [operation('waiting_for_idle', { apply: 'after_turn', waiting_since: new Date(now - 4 * 60000).toISOString() })]
    : state === 'still_waiting' ? [operation('waiting_for_idle', { apply: 'after_turn', waiting_since: new Date(now - 42 * 60000).toISOString() })]
      : [];
const bridge = (id: string, label: string, os: string, online: boolean) => ({ bridge_id: id, label, machine_hostname: label, machine_os: os,
  status: online ? 'online' : 'offline', runtime_connected: online, reconfiguration_supported: true });
const bridges = [
  bridge('brg_riverwood', 'riverwood', 'Fedora Atomic', true),
  bridge('brg_dawnstar', 'dawnstar', 'Linux', true),
  bridge('brg_kamsharm', 'kamsharm-mn4988.linkedin.biz', 'macOS', true),
  bridge('brg_macbook', 'Tanmays-MacBook-Pro.local', 'macOS', false),
  bridge('brg_laptop', 'LAPTOP-KLN2J0EM', 'Windows', false),
];
const bridgePaths = [
  { bridge_id: 'brg_riverwood', path: '/var/home/tanmay/heimdall-agent-manager' },
  { bridge_id: 'brg_dawnstar', path: '/home/tanmay/heimdall-agent-manager' },
  { bridge_id: 'brg_kamsharm', path: '/Users/kamsharm/heimdall-agent-manager' },
];
const checkedAt = new Date(now - 30 * 60000).toISOString();
const providerStatus = {
  providers: [
    { provider: 'claude', display_name: 'Claude Code', enabled: true, state: 'present', catalog_state: 'active', version_text: '2.1.0', checked_at: checkedAt,
      models: [{ model_id: 'default', state: 'active' }, { model_id: 'claude-sonnet-5-5', state: 'active' }, { model_id: 'claude-opus-5-5', state: 'active' }],
      acp_availability: { available: acpReason === 'ready', reason: acpReason, fix: ACP_FIX[acpReason] ?? null } },
    { provider: 'codex', display_name: 'Codex', enabled: true, state: 'present', catalog_state: 'active', version_text: '0.98.0', checked_at: checkedAt,
      models: [{ model_id: 'gpt-5', state: 'active' }], acp_availability: { available: true, reason: 'ready', fix: null } },
    { provider: 'gemini', display_name: 'Gemini CLI', enabled: false, state: 'absent', catalog_state: 'active', version_text: '', models: [] },
  ],
};

window.fetch = async (input, init = {}) => {
  const path = new URL(String(input), location.origin).pathname;
  const json = (data: any, status = 200) => new Response(JSON.stringify({ data }), { status, headers: { 'content-type': 'application/json' } });
  if (path.endsWith('/me/experiments')) return json({ experiments: [{ key: 'agent_settings_panel', enabled: true }] });
  if (path.includes('/chats/by-instance/')) return json({ conversation_id: 'conv', agent_instance_id: 'inst_coord', agent_id: 'agt_coord', title: 'coordinator #41', project_id: 'prj_heimdall', runtime_status: instance.runtime_status });
  if (path.endsWith('/messages')) return json([...messages].reverse());
  if (path.endsWith('/send-now')) return json({ conversation_id: 'conv', runtime_transport: 'pty', launch_epoch: 'ep1', steering_supported: false, batch: null });
  if (/\/agent-instances\/[^/]+$/.test(path)) return json(instance);
  if (path.endsWith('/reconfigurations') && String(init.method || 'GET').toUpperCase() === 'POST') {
    const body = JSON.parse(String(init.body || '{}'));
    (window as any).__reconfigurations = [...((window as any).__reconfigurations || []), body];
    const accepted = operation(body.apply === 'after_turn' && instance.activity_status === 'working' ? 'waiting_for_idle' : 'prepared',
      { operation_id: 'op_applied', idempotency_key: body.idempotency_key, apply: body.apply, waiting_since: new Date().toISOString(),
        destination: { bridge_id: body.bridge_id, project_id: body.project_id, provider: body.provider, provider_profile: body.provider_profile, model: body.model } });
    operations = [accepted];
    return json(accepted);
  }
  if (path.endsWith('/reconfigurations')) return json({ operations });
  if (path.endsWith('/provider-status') || path.endsWith('/providers')) return json(providerStatus);
  if (path.endsWith('/bridges')) return json(bridges);
  if (/\/projects\/[^/]+$/.test(path)) return json({ project: { project_id: 'prj_heimdall', name: 'heimdall-agent-manager (3)', state: 'active', status: 'active', bridge_paths: bridgePaths }, bridge_paths: bridgePaths });
  if (/\/agents\/[^/]+$/.test(path)) return json({ agent_id: 'agt_coord', name: 'coordinator' });
  if (path.endsWith('/attention')) return json({ items: [] });
  return json([]);
};

createRoot(document.getElementById('root')!).render(
  <Provider store={store}>
    <ShortcutProvider>
      <AgentChatPane {...({ agentInstanceId: 'inst_coord', paneId: 'fixture-pane' } as any)} />
    </ShortcutProvider>
  </Provider>,
);
