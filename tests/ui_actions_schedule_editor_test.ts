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
    // Verify the surviving component still edits its own config, using the native date picker.
    await type(fields[0].querySelector('input[aria-label="Blackout dates"]')!, '2026-12-31');
    assert.equal((fields[0].querySelector('input[aria-label="Blackout dates"]') as HTMLInputElement).value, '');
    const form = emptyActionForm();
    form.triggers = current;
    const wire = actionFormBody(form).triggers!;
    assert.deepEqual(wire[0].config.blackout_dates, ['2026-12-31']);
    assert.equal('clientKey' in wire[0], false);
    await click(fields[0].querySelector('[role="combobox"][aria-label="Schedule mode"]'));
    await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === 'once')!);
    assert.equal(current[0].config.run_at, '');
    const once = doc.querySelector('input[aria-label="Once at"]') as HTMLInputElement;
    assert.equal(once.value, '');
    assert.equal(doc.body.textContent?.includes('This time has passed'), false);
    await type(once, '2000-01-01T00:00');
    assert.ok(doc.body.textContent?.includes('This time has passed; the action runs as soon as you save'));
    await type(once, '2999-01-01T00:00');
    assert.equal(doc.body.textContent?.includes('This time has passed'), false);
    assert.equal(once.type, 'datetime-local');
    await type(doc.querySelector('input[aria-label="Time zone"]')!, 'Asia/Kolkata');
    await type(doc.querySelector('input[aria-label="Once at"]')!, '2026-12-01T09:00');
    assert.equal(current[0].config.run_at, '2026-12-01T09:00:00+05:30');
    assert.ok(doc.body.textContent?.includes('2026-12-01T03:30:00.000Z'));
    for (const label of ['Active from', 'Active until']) {
      const input = doc.querySelector('input[aria-label="' + label + '"]') as HTMLInputElement;
      await type(input, '2026-12-02T09:00');
      const key = label === 'Active from' ? 'active_from' : 'active_until';
      assert.equal(current[0].config[key], '2026-12-02T09:00:00+05:30');
      await type(input, '');
      assert.equal(current[0].config[key], '');
    }
    await click(doc.querySelector('[aria-label="Remove blackout date 2026-12-31"]'));
    assert.deepEqual(current[0].config.blackout_dates, []);
    const blackout = doc.querySelector('input[aria-label="Blackout dates"]') as HTMLInputElement;
    assert.equal(blackout.type, 'date');
    await type(blackout, '2026-12-25');
    await type(blackout, '2026-12-25');
    assert.deepEqual(current[0].config.blackout_dates, ['2026-12-25']);
    // Reopen stored offset and fractional-second values, then edit an unrelated
    // field and serialize through the actual action model.
    const stored = { mode: 'once', timezone: 'Asia/Kolkata', run_at: '2026-12-01T03:30:12.123456789Z', active_from: '2026-11-01T09:00:00-04:00', active_until: '2027-01-01T00:00:00+00:00', blackout_dates: [] };
    let reopened: any = stored;
    const ScheduleEditor = (await import('../src/ui/components/actions/ScheduleEditor.tsx')).default;
    function Reopened() {
      const [config, setConfig] = React.useState<any>(stored);
      reopened = config;
      return React.createElement('form', {}, React.createElement(ScheduleEditor, { value: config, onChange: setConfig }));
    }
    await React.act(async () => root.render(React.createElement(Reopened)));
    assert.equal(reopened, stored);
    assert.equal((doc.querySelector('[aria-label="Once at"]') as HTMLInputElement).value, '2026-12-01T09:00:12.123');
    await type(doc.querySelector('[aria-label="Blackout dates"]')!, '2026-12-25');
    const reopenedForm = emptyActionForm();
    reopenedForm.triggers = [{ kind: 'schedule', config: reopened }] as any;
    const config = actionFormBody(reopenedForm).triggers![0].config;
    for (const key of ['run_at', 'active_from', 'active_until']) assert.equal(config[key], (stored as any)[key]);
    await type(doc.querySelector('[aria-label="Time zone"]')!, 'America/New_York');
    await type(doc.querySelector('[aria-label="Active from"]')!, '2026-03-08T02:30');
    assert.ok(doc.body.textContent?.includes('This time does not exist'));
    assert.equal(doc.querySelector('form')!.checkValidity(), false);
    await type(doc.querySelector('[aria-label="Active from"]')!, '');
    assert.equal(doc.querySelector('form')!.checkValidity(), true);
  } finally {
    if (root) await React.act(async () => root.unmount());
    dom.window.close();
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(g, name, descriptor);
      else delete g[name];
    }
  }
});
