// Actual bot page and artifact endpoint client, with an isolated synthetic Hub.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import BotChatPage from '../../../src/ui/components/bots/BotChatPage';
import { heimdallApi } from '../../../src/ui/api/heimdallApi';
import vault from '../../../src/ui/store/vaultSlice';
import auxPanes from '../../../src/ui/store/auxPanesSlice';
import '../../../src/ui/styles.css';
const messages: any[] = [], artifacts = new Map<string, any>();
const original = window.fetch;
(window as any).botAttachments = { messages, artifacts, failUpload: false };
window.fetch = async (input, init = {}) => {
 const path = new URL(String(input), location.href).pathname.replace('/api/v1', '');
 const body = init.body ? JSON.parse(String(init.body)) : {};
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
const store = configureStore({ reducer: { vault, auxPanes, chat: (s = { session: {} }) => s, [heimdallApi.reducerPath]: heimdallApi.reducer },
 middleware: g => g({ serializableCheck: false }).concat(heimdallApi.middleware) });
document.documentElement.classList.add('dark');
document.body.style.margin = '0';
createRoot(document.getElementById('root')!).render(<Provider store={store}><div className="bg-canvas text-primary" style={{ height: '100dvh', display: 'flex' }}><BotChatPage /></div></Provider>);
