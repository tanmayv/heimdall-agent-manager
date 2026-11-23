import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { actionFormBody, emptyActionForm } from '../src/ui/components/actions/actionModel.ts';

test('new triggers retain their blackout input after removing an earlier trigger; once requires an explicit time', async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/#/actions/new', pretendToBeVisual: true });
  const g = globalThis as any;
  const names = ['window', 'document', 'HTMLElement', 'HTMLInputElement', 'Node', 'getComputedStyle', 'requestAnimationFrame', 'cancelAnimationFrame', 'IS_REACT_ACT_ENVIRONMENT', 'CSS'];
  const previous = new Map(names.map(name => [name, Object.getOwnPropertyDescriptor(g, name)]));
  for (const name of names) Object.defineProperty(g, name, { configurable: true, writable: true, value: name === 'IS_REACT_ACT_ENVIRONMENT' ? true : (dom.window as any)[name] });
  g.CSS = { escape: (value: string) => value.replace(/[^a-zA-Z0-9_-]/g, char => '\\' + char) };
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  let root: any;
  try {
    const { createRoot } = await import('react-dom/client');
    const Editor = (await import('../src/ui/components/actions/TriggerListEditor.tsx')).default;
    const types: any = { schedules_supported: true, limits: { max_triggers: 16 }, trigger_kinds: [] };
    let current: any[] = [];
    function Harness() {
      const [triggers, setTriggers] = React.useState<any[]>([]);
      current = triggers;
      return React.createElement(Editor, { value: triggers, onChange: setTriggers, types });
    }
    root = createRoot(dom.window.document.getElementById('root')!);
    await React.act(async () => root.render(React.createElement(Harness)));
    const doc = dom.window.document;
    const click = async (node: Element | null) => {
      assert.ok(node);
      await React.act(async () => node.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })));
    };
    const type = async (input: HTMLInputElement, value: string) => {
      await React.act(async () => {
        Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value')!.set!.call(input, value);
        input.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
      });
    };
    await click(doc.querySelector('[data-debug-id="action-trigger-add-schedule"]'));
    await click(doc.querySelector('[data-debug-id="action-trigger-add-schedule"]'));
    const keys = current.map(t => t.clientKey);
    assert.equal(new Set(keys).size, 2);
    let fields = doc.querySelectorAll('fieldset');
    await type(fields[0].querySelector('input[aria-label="Blackout dates"]')!, '2026-12-25');
    assert.deepEqual(current[0].config.blackout_dates, ['2026-12-25']);
    await click(fields[0].querySelector('[data-debug-id^="action-trigger-remove-"]'));
    fields = doc.querySelectorAll('fieldset');
    assert.equal(fields.length, 1);
    assert.equal((fields[0].querySelector('input[aria-label="Blackout dates"]') as HTMLInputElement).value, '');
    assert.deepEqual(current[0].config.blackout_dates, []);
    assert.equal(current[0].clientKey, keys[1]);
    // Verify the surviving component still edits its own config, including a comma in progress.
    await type(fields[0].querySelector('input[aria-label="Blackout dates"]')!, '2026-12-31,');
    assert.equal((fields[0].querySelector('input[aria-label="Blackout dates"]') as HTMLInputElement).value, '2026-12-31,');
    const form = emptyActionForm();
    form.triggers = current;
    const wire = actionFormBody(form).triggers!;
    assert.deepEqual(wire[0].config.blackout_dates, ['2026-12-31']);
    assert.equal('clientKey' in wire[0], false);
    await click(fields[0].querySelector('[role="combobox"][aria-label="Schedule mode"]'));
    await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === 'interval')!);
    await type(doc.querySelector('input[aria-label="Interval seconds"]')!, '120');
    assert.equal(current[0].config.interval_s, 120);
    await click(fields[0].querySelector('[role="combobox"][aria-label="Schedule mode"]'));
    await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === 'once')!);
    assert.equal(current[0].config.mode, 'once');
    assert.equal('interval_s' in current[0].config, false);
    assert.equal(current[0].config.run_at, '');
    const once = doc.querySelector('input[aria-label="Once at"]') as HTMLInputElement;
    assert.equal(once.value, '');
    assert.equal(doc.body.textContent?.includes('This time has passed'), false);
    await type(once, '2000-01-01T00:00:00Z');
    assert.ok(doc.body.textContent?.includes('This time has passed; the action runs as soon as you save'));
    await type(once, '2999-01-01T00:00:00Z');
    assert.equal(doc.body.textContent?.includes('This time has passed'), false);
    form.triggers = current;
    const saved = JSON.parse(JSON.stringify(actionFormBody(form)));
    assert.equal(saved.triggers[0].config.mode, 'once');
    assert.equal(saved.triggers[0].config.run_at, '2999-01-01T00:00:00Z');
    assert.equal('interval_s' in saved.triggers[0].config, false);
  } finally {
    if (root) await React.act(async () => root.unmount());
    dom.window.close();
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(g, name, descriptor);
      else delete g[name];
    }
  }
});
