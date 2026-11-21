// Actual bot page and artifact endpoint client, with an isolated synthetic Hub.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { AgentChatPane } from '../../../src/ui/components/workbench/AgentChatPane';
import { ShortcutProvider } from '../../../src/ui/services/shortcuts/ShortcutContext';
import BotChatPage from '../../../src/ui/components/bots/BotChatPage';
import { heimdallApi } from '../../../src/ui/api/heimdallApi';
import { keyringInstalled } from '../../../src/ui/store/vaultSlice';
import { importKeyring, serializeKeyringBytes } from '../../../src/ui/utils/vaultKeyring';
import { setActiveVaultKey } from '../../../src/ui/utils/vaultContent';
import '../../../src/ui/styles.css';
const showAgent = new URLSearchParams(location.search).has('agent');
const messages: any[] = [], artifacts = new Map<string, any>();
const original = window.fetch;
(window as any).botAttachments = { messages, artifacts, failUpload: false };
window.fetch = async (input, init = {}) => {
 const path = new URL(String(input), location.href).pathname.replace('/api/v1', '');
 const body = init.body ? JSON.parse(String(init.body)) : {};
 if (showAgent && !path.startsWith('/artifacts') && !path.startsWith('/bots/')) {
  const data = (data: any) => Response.json({ data });
  if (path.includes('/chats/by-instance/')) return data({ conversation_id: 'chat_fixture', agent_instance_id: 'inst_fixture', agent_id: 'agt_fixture', runtime_status: 'running' });
  if (path.endsWith('/messages')) return data([{ message_id: 'chm_example', direction: 'agent_to_user', sender_agent_instance_id: 'inst_fixture', body: 'Here is the document you requested.', artifact_ids: ['art_example'], created_unix_ms: 1795243200000 }]);
  if (/\/agent-instances\/[^/]+$/.test(path)) return data({ agent_instance_id: 'inst_fixture', agent_id: 'agt_fixture', provider: 'claude', model: 'opus', bridge_id: 'brg_fixture', runtime_status: 'running' });
  if (path.endsWith('/reconfigurations')) return data({ operations: [] });
  if (path.endsWith('/provider-status')) return data({ providers: [{ provider: 'claude', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'opus', state: 'active' }] }] });
  if (path.endsWith('/bridges')) return data([{ bridge_id: 'brg_fixture', status: 'online', runtime_connected: true, reconfiguration_supported: true }]);
  if (path.endsWith('/attention')) return data({ items: [] });
  return data([]);
 }
 if (!path.startsWith('/bots/') && !path.startsWith('/artifacts') && path !== '/me/experiments') return original(input, init);
 const data = (data: any, status = 200) => Response.json({ data }, { status });
 if (path === '/me/experiments') return data({ experiments: [{ key: 'bots', enabled: true }] });
 if (path === '/bots/me') return data({ bot_id: 'bot_fixture', display_name: 'Ninjy bot', status: 'ready', status_detail: '',
  telegram: null, whatsapp: null, advanced: { agent_instance_id: 'inst_fixture' } });
 if (path === '/bots/me/messages') return data({ messages: [...messages].reverse(), next_cursor: '' });
 if (path === '/artifacts' && init.method === 'POST') {
  if ((window as any).botAttachments.failUpload) return Response.json({ error: { message: 'Upload unavailable. Try again.' } }, { status: 503 });
  const artifact_id = 'art_fixture_' + artifacts.size;
  artifacts.set(artifact_id, { ...body, artifact_id, content_type: body.mime });
  return data(artifacts.get(artifact_id), 201);
 }
 if (path.startsWith('/artifacts/')) {
  const artifact = artifacts.get(path.split('/')[2]);
  if (path.endsWith('/content')) return new Response(Uint8Array.from(atob(artifact.content_base64), c => c.charCodeAt(0)), { headers: { 'content-type': artifact.mime } });
  return data(artifact);
 }
 if (path === '/bots/me/channels/web/messages') {
  const message_id = 'chm_fixture_' + messages.length;
  messages.push({ message_id, binding_id: 'chb_fixture', provider: 'web', direction: 'inbound', body: body.text, body_purged: false,
   send_state: '', created_at: new Date().toISOString(), read_at: '', replied_at: '',
   attachments: (body.artifact_ids ?? []).map((id: string) => ({ artifact_id: id, state: 'stored' })) });
  return data({ message_id, created: true }, 201);
 }
 throw new Error('Unexpected fixture request: ' + path);
};
const reducers: Record<string, any> = {};
const modules: Record<string, string> = { chat: 'chatSlice', vault: 'vaultSlice', tasks: 'taskSlice', memory: 'memorySlice', projects: 'projectSlice',
home: 'homeSlice', chainView: 'chainViewSlice', attention: 'attentionSlice', cards: 'cardsSlice', toasts: 'toastSlice', notifications: 'notificationsSlice',
workspaceLayout: 'workspaceLayoutSlice', auxPanes: 'auxPanesSlice', workspaceChrome: 'workspaceChromeSlice', inputPreferences: 'inputPreferencesSlice',
searchTitle: 'searchTitleSlice', agentActivity: 'agentActivitySlice', toolActivity: 'toolActivitySlice', deviceVault: 'deviceVaultSlice', shells: 'shellSlice', theme: 'themeSlice', composerContext: 'composerContextSlice' };
const loaders = import.meta.glob('../../../src/ui/store/*.ts');
for (const [key, file] of Object.entries(modules)) reducers[key] = ((await loaders['../../../src/ui/store/' + file + '.ts']()) as any).default;
const store = configureStore({ reducer: { ...reducers, [heimdallApi.reducerPath]: heimdallApi.reducer },
 middleware: g => g({ serializableCheck: false }).concat(heimdallApi.middleware) });
if (new URLSearchParams(location.search).has('compare')) {
artifacts.set('art_example', { artifact_id: 'art_example', name: 'reference.pdf', mime: 'application/pdf', content_type: 'application/pdf', content_base64: btoa('%PDF-1.4 fixture') });
messages.push({ message_id: 'chm_example', binding_id: 'chb_fixture', provider: 'web', direction: 'outbound', body: 'Here is the document you requested.', body_purged: false, send_state: 'sent', created_at: '2026-11-21T06:40:00Z', read_at: '', replied_at: '', attachments: [{ artifact_id: 'art_example', state: 'stored' }] });
}
if (showAgent) {
  setActiveVaultKey(await importKeyring(serializeKeyringBytes({ userId: 'usr_fixture', vaultId: '7e57000000000001', currentEpoch: 1, entries: [{ epoch: 1, key: new Uint8Array(32).fill(63) }] })));
  store.dispatch(keyringInstalled({ currentEpoch: 1 }));
}
document.documentElement.classList.add('dark');
document.body.style.margin = '0';
createRoot(document.getElementById('root')!).render(<Provider store={store}><div className="bg-canvas text-primary" style={{ height: '100dvh', display: 'flex' }}><ShortcutProvider>{showAgent ? <AgentChatPane agentInstanceId="inst_fixture" paneId="fixture" isMobile={true} /> : <BotChatPage />}</ShortcutProvider></div></Provider>);
