// Isolated review fixture: real editor/components, no live API or mutations.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { Panel, Text } from '../../src/ui/components/ui';
import TriggerListEditor from '../../src/ui/components/actions/TriggerListEditor';
import { heimdallApi } from '../../src/ui/api/heimdallApi';
import vaultReducer from '../../src/ui/store/vaultSlice';
import type { TriggerTypes } from '../../src/ui/api/endpoints/actions';
import type { FormTrigger } from '../../src/ui/components/actions/actionModel';
import '../../src/ui/styles.css';

// The app pins its document to a viewport and scrolls panes. This isolated
// fixture has no app pane, so let the document scroll for full-page evidence.
for (const element of [document.documentElement, document.body, document.getElementById('root')!]) {
  Object.assign(element.style, { height: 'auto', maxHeight: 'none', overflow: 'visible', position: 'static' });
}

const types: TriggerTypes = {
  target_kinds: ['agent'], schedules_supported: true,
  limits: { max_triggers: 8, max_rules: 8, min_interval_s: { min: 0, max: 86400, default: 30 }, filter: { max_depth: 4, max_nodes: 24, max_checks: 16, max_children: 16, max_values: 32, max_value_bytes: 256, max_field_bytes: 128, max_path_segments: 4, max_segment_bytes: 64, max_bytes: 4096 } },
  trigger_kinds: [{ kind: 'event', label: 'Event', events: [{ event_type: 'webhook.received', label: 'Webhook received', scope: 'webhook', no_delay: true, free_data_paths: true, fields: [], presets: [] }] }],
};
const initial: FormTrigger[] = [{ clientKey: 'review', kind: 'event', enabled: true, delay_s: 0, config: { event_type: 'webhook.received', filter: { all: [
  { field: 'data.action', op: 'in', value: ['opened', 'reopened'] },
  { any: [{ field: 'data.repo.name', op: 'prefix', value: 'heimdall-' }, { field: 'data.labels.urgent', op: 'exists', value: true }] },
  { not: { field: 'data.draft', op: 'eq', value: true } },
] } } }];
window.fetch = async input => {
  if (String(input).includes('/actions/filter-test')) return new Response(JSON.stringify({ data: { valid: true, matched: true, nodes: 'TTTTTFT', path: '', reason: '' } }), { headers: { 'content-type': 'application/json' } });
  return new Response(JSON.stringify({ data: [] }), { headers: { 'content-type': 'application/json' } });
};
const store = configureStore({ reducer: { vault: vaultReducer, [heimdallApi.reducerPath]: heimdallApi.reducer }, middleware: g => g({ serializableCheck: false }).concat(heimdallApi.middleware) });
function Fixture() {
  const [value, onChange] = React.useState(initial);
  return <main className="bg-surface text-primary" style={{ padding: 'var(--space-4)' }}>
    <div className="mx-auto flex max-w-3xl flex-col" style={{ gap: 'var(--space-4)' }}>
      <Text as="h1" role="display">Event conditions</Text>
      <Text role="body-sm" tone="muted">Deliver this action when a webhook matches your conditions.</Text>
      <Panel style={{ padding: 'var(--space-4)' }}><TriggerListEditor value={value} onChange={onChange} types={types} /></Panel>
    </div>
  </main>;
}
createRoot(document.getElementById('root')!).render(<Provider store={store}><Fixture /></Provider>);
