import React from 'react';
import { createRoot } from 'react-dom/client';
import { Panel, Text } from '../../src/ui/components/ui';
import { RunMatch, runRowText } from '../../src/ui/components/actions/RunHistory';
import WebhooksSection from '../../src/ui/components/actions/WebhooksSection';
import '../../src/ui/styles.css';
for (const element of [document.documentElement, document.body, document.getElementById('root')!]) {
  Object.assign(element.style, { height: 'auto', maxHeight: 'none', overflow: 'visible', position: 'static' });
}
const row = { webhook_id: 'wh_ci', name: 'CI events', enabled: true, last_received_at: '' };
window.fetch = async (input, init = {}) => new Response(JSON.stringify({ data: init.method === 'POST' ? { webhook: row, token: 'example-only-token' } : [row] }), { headers: { 'content-type': 'application/json' } });
const triggers: any = [{ id: 'tr', kind: 'event', rev: 7, enabled: true, config: { event_type: 'webhook.received', filter: { all: [
  { field: 'data.action', op: 'in', value: ['opened', 'reopened'] },
  { any: [{ field: 'data.repo.name', op: 'prefix', value: 'heimdall-' }, { field: 'data.labels.urgent', op: 'exists', value: true }] },
  { not: { field: 'data.draft', op: 'eq', value: true } },
] } } }];
const run: any = { id: 'review', trigger_id: 'tr', event_params: { _match: { rev: 7, nodes: 'TTTFTTF' }, data: { action: 'opened', repo: { name: 'docs-site' }, labels: { urgent: true }, draft: false } } };
function Fixture() { return <main className="bg-surface text-primary" style={{ padding: 'var(--space-4)' }}>
  <div className="mx-auto flex max-w-3xl flex-col gap-4">
    <Text as="h1" role="display">Run history and webhooks</Text>
    <Panel className="p-4"><Text as="h2" role="title">Matched run</Text><RunMatch run={run} triggers={triggers} /></Panel>
    <Panel className="p-4"><RunMatch run={{ ...run, id: 'edited', event_params: { ...run.event_params, _match: { rev: 6, nodes: 'T' } } }} triggers={triggers} /></Panel>
    <Panel className="p-4"><p>{runRowText({ ...run, state: 'delivered', batch_size: 3 })}</p><p>{runRowText({ ...run, state: 'deferred', target_instance_id: 'inst' })}</p></Panel>
    <WebhooksSection />
  </div>
</main>; }
createRoot(document.getElementById('root')!).render(<Fixture />);
