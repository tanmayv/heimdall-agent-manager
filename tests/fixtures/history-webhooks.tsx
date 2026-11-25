import React from 'react';
import { createRoot } from 'react-dom/client';
import { Text } from '../../src/ui/components/ui';
import { ActionDetailBody } from '../../src/ui/components/actions/ActionDetail';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { heimdallApi } from '../../src/ui/api/heimdallApi';
import vaultReducer from '../../src/ui/store/vaultSlice';
import WebhooksSection from '../../src/ui/components/actions/WebhooksSection';
import '../../src/ui/styles.css';
for (const element of [document.documentElement, document.body, document.getElementById('root')!]) {
  Object.assign(element.style, { height: 'auto', maxHeight: 'none', overflow: 'visible', position: 'static' });
}
const row = { webhook_id: 'wh_ci', name: 'CI events', dedupe_header: 'Idempotency-Key', enabled: true, last_received_at: '' };
const triggers: any = [{ id: 'tr', kind: 'event', rev: 7, enabled: true, config: { event_type: 'webhook.received', filter: { all: [
  { field: 'data.action', op: 'in', value: ['opened', 'reopened'] },
  { any: [{ field: 'data.repo.name', op: 'prefix', value: 'heimdall-' }, { field: 'data.labels.urgent', op: 'exists', value: true }] },
  { not: { field: 'data.draft', op: 'eq', value: true } },
] } } }];
const run: any = { id: 'review', trigger_id: 'tr', event_params: { _match: { rev: 7, nodes: 'TTTFTTF' }, data: { action: 'opened', repo: { name: 'docs-site' }, labels: { urgent: true }, draft: false } } };

const runs = [
  { ...run, event_type: 'webhook.received', state: 'delivered', batch_size: 3, joined_count: 0, created_at: '2026-11-25T05:00:00Z', target_instance_id: '' },
  { ...run, id: 'edited', event_type: 'webhook.received', state: 'delivered', joined_count: 0, created_at: '2026-11-25T04:00:00Z', target_instance_id: '', event_params: { ...run.event_params, _match: { rev: 6, nodes: 'T' } } },
  { ...run, id: 'parked', event_type: 'webhook.received', state: 'deferred', joined_count: 0, created_at: '2026-11-25T03:00:00Z', target_instance_id: 'inst' },
];
window.fetch = async (input, init = {}) => {
  const url = String(input);
  const data = url.includes('/actions/review/runs') ? runs
    : url.includes('/webhooks') ? init.method === 'POST' ? { webhook: row, token: 'example-only-token' } : [row]
    : [];
  return new Response(JSON.stringify({ data }), { headers: { 'content-type': 'application/json' } });
};
const store = configureStore({ reducer: { vault: vaultReducer, [heimdallApi.reducerPath]: heimdallApi.reducer }, middleware: g => g({ serializableCheck: false }).concat(heimdallApi.middleware) });
const action: any = { id: 'review', name: 'Review webhook', prompt_text: 'Summarize the incoming webhook.', enabled: true, target: { kind: 'instance', instance_id: 'inst' }, triggers };
function Fixture() { return <main className="bg-surface text-primary" style={{ padding: 'var(--space-4)' }}>
  <div className="mx-auto flex max-w-3xl flex-col gap-4">
    <Text as="h1" role="display">Run history and webhooks</Text>
    <ActionDetailBody record={action} />
    <WebhooksSection />
  </div>
</main>; }
createRoot(document.getElementById('root')!).render(<Provider store={store}><Fixture /></Provider>);
