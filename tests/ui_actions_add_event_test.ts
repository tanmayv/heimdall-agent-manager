import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import TriggerListEditor from '../src/ui/components/actions/TriggerListEditor.tsx';
import { actionFormBody, emptyActionForm, type FormTrigger } from '../src/ui/components/actions/actionModel.ts';
import type { TriggerTypes } from '../src/ui/api/endpoints/actions.ts';

test('Add Event emits a tree-only config that survives form serialization', () => {
  let emitted: FormTrigger[] = [];
  const types = {
    limits: { max_triggers: 8 },
    trigger_kinds: [{ kind: 'event', events: [{ event_type: 'chain.state' }] }],
  } as TriggerTypes;
  const root = TriggerListEditor({ value: [], onChange: next => { emitted = next; }, types });
  function find(node: React.ReactNode): React.ReactElement<any> | undefined {
    for (const child of React.Children.toArray(node)) {
      if (!React.isValidElement<any>(child)) continue;
      if (child.props['data-debug-id'] === 'action-trigger-add-event') return child;
      const match = find(child.props.children);
      if (match) return match;
    }
  }
  const add = find(root);
  assert.ok(add);
  assert.equal(add.props.disabled, false);
  add.props.onClick();
  assert.equal(emitted.length, 1);
  assert.equal(emitted[0].kind, 'event');
  assert.deepEqual(emitted[0].config, { event_type: 'chain.state', filter: {} });
  assert.equal('data' in emitted[0].config, false);
  const form = emptyActionForm();
  form.triggers = emitted;
  assert.deepEqual(actionFormBody(form).triggers?.[0].config, emitted[0].config);
});
