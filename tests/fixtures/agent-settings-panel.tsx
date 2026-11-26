// Browser-only fixture: the real AgentChatPane with the Agent settings panel against an
// in-memory hub. ?state=running|stopped|restarting. No request leaves the page.
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

const state = new URLSearchParams(location.search).get('state') || 'running';
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
  runtime_status: state === 'stopped' ? 'stopped' : 'running', activity_status: state === 'running' ? 'working' : 'idle',
  started_at: state === 'stopped' ? '' : startedAt, stop_reason: state === 'stopped' ? 'user_stop' : '', display_name: 'coordinator #41',
};
const operations = state === 'restarting'
  ? [{ operation_id: 'op1', agent_instance_id: 'inst_coord', idempotency_key: 'k', phase: 'launching', revision: 3, source: {}, destination: {}, source_stopped: true, destination_committed: true, failure_code: '', failure_message: '' }]
  : [];
const bridges = [{ bridge_id: 'brg_riverwood', label: 'riverwood', machine_hostname: 'riverwood', machine_os: 'Fedora Atomic', status: 'online', runtime_connected: true, reconfiguration_supported: true }];

window.fetch = async (input, init = {}) => {
  const path = new URL(String(input), location.origin).pathname;
  const json = (data: any, status = 200) => new Response(JSON.stringify({ data }), { status, headers: { 'content-type': 'application/json' } });
  if (path.endsWith('/me/experiments')) return json({ experiments: [{ key: 'agent_settings_panel', enabled: true }] });
  if (path.includes('/chats/by-instance/')) return json({ conversation_id: 'conv', agent_instance_id: 'inst_coord', agent_id: 'agt_coord', title: 'coordinator #41', project_id: 'prj_heimdall', runtime_status: instance.runtime_status });
  if (path.endsWith('/messages')) return json([...messages].reverse());
  if (path.endsWith('/send-now')) return json({ conversation_id: 'conv', runtime_transport: 'pty', launch_epoch: 'ep1', steering_supported: false, batch: null });
  if (/\/agent-instances\/[^/]+$/.test(path)) return json(instance);
  if (path.endsWith('/reconfigurations')) return json({ operations });
  if (path.endsWith('/provider-status') || path.endsWith('/providers')) return json({ providers: [
    { provider: 'claude', display_name: 'Claude Code', enabled: true, state: 'present', catalog_state: 'active', version_text: '2.1.0', models: [{ model_id: 'default', state: 'active' }, { model_id: 'claude-sonnet-5-5', state: 'active' }] },
    { provider: 'codex', display_name: 'Codex', enabled: true, state: 'present', catalog_state: 'active', version_text: '0.98.0', models: [{ model_id: 'gpt-5', state: 'active' }] },
  ] });
  if (path.endsWith('/bridges')) return json(bridges);
  if (/\/projects\/[^/]+$/.test(path)) return json({ project: { project_id: 'prj_heimdall', name: 'heimdall-agent-manager (3)', state: 'active', status: 'active' } });
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
