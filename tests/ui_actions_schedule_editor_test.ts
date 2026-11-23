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
    assert.equal(current[0].config.mode, 'interval');
    assert.equal(current[0].config.interval_s, 3600);
    assert.equal((doc.querySelector('[aria-label="Interval"]') as HTMLInputElement).value, '1');
    await click(doc.querySelector('[aria-label="Schedule mode"]'));
    assert.deepEqual(Array.from(doc.querySelectorAll('[role="option"]')).map(node => node.textContent), ['interval', 'once', 'cron']);
    await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === 'interval')!);
    const keys = current.map(t => t.clientKey);
    assert.equal(new Set(keys).size, 2);
    let fields = doc.querySelectorAll('fieldset');
    await type(fields[0].querySelector('input[aria-label="Blackout dates"]')!, '2026-12-25');
    assert.deepEqual(current[0].config.blackout_dates, []);
    await click(fields[0].querySelector('[aria-label="Add blackout date"]'));
    assert.deepEqual(current[0].config.blackout_dates, ['2026-12-25']);
    await click(fields[0].querySelector('[data-debug-id^="action-trigger-remove-"]'));
    fields = doc.querySelectorAll('fieldset');
    assert.equal(fields.length, 1);
    assert.equal((fields[0].querySelector('input[aria-label="Blackout dates"]') as HTMLInputElement).value, '');
    assert.deepEqual(current[0].config.blackout_dates, []);
    assert.equal(current[0].clientKey, keys[1]);
    // Verify the surviving component still edits its own config, using the native date picker.
    await type(fields[0].querySelector('input[aria-label="Blackout dates"]')!, '2026-12-31');
    assert.equal((fields[0].querySelector('input[aria-label="Blackout dates"]') as HTMLInputElement).value, '2026-12-31');
    await click(fields[0].querySelector('[aria-label="Add blackout date"]'));
    assert.equal((fields[0].querySelector('input[aria-label="Blackout dates"]') as HTMLInputElement).value, '');
    const form = emptyActionForm();
    form.triggers = current;
    const wire = actionFormBody(form).triggers!;
    assert.deepEqual(wire[0].config.blackout_dates, ['2026-12-31']);
    assert.equal('clientKey' in wire[0], false);
    await type(doc.querySelector('input[aria-label="Active from"]')!, '2026-01-01T00:00');
    await type(doc.querySelector('input[aria-label="Active until"]')!, '2027-01-01T00:00');
    await click(fields[0].querySelector('[role="combobox"][aria-label="Schedule mode"]'));
    await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === 'once')!);
    assert.equal(current[0].config.run_at, '');
    for (const label of ['Active from', 'Active until', 'Blackout dates']) assert.equal(doc.querySelector('[aria-label="' + label + '"]'), null);
    form.triggers = current;
    const oncePayload = actionFormBody(form).triggers![0].config;
    for (const key of ['active_from', 'active_until', 'blackout_dates']) assert.equal(key in oncePayload, false);
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
    assert.equal((doc.querySelector('[aria-label="Once at"]') as HTMLInputElement).value, '2026-12-01T09:00');
    assert.ok(doc.body.textContent?.includes('2026-12-01T03:30:00.000Z'));
    await click(doc.querySelector('[role="combobox"][aria-label="Schedule mode"]'));
    await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === 'interval')!);
    for (const label of ['Active from', 'Active until']) {
      const input = doc.querySelector('input[aria-label="' + label + '"]') as HTMLInputElement;
      await type(input, '2026-12-02T09:00');
      const key = label === 'Active from' ? 'active_from' : 'active_until';
      assert.equal(current[0].config[key], '2026-12-02T09:00:00+05:30');
      await type(input, '');
      assert.equal(current[0].config[key], '');
    }
    assert.deepEqual(current[0].config.blackout_dates, []);
    const blackout = doc.querySelector('input[aria-label="Blackout dates"]') as HTMLInputElement;
    assert.equal(blackout.type, 'date');
    await type(blackout, '0002-12-25');
    assert.deepEqual(current[0].config.blackout_dates, []);
    assert.equal((doc.querySelector('[aria-label="Add blackout date"]') as HTMLButtonElement).disabled, true);
    await click(doc.querySelector('[aria-label="Add blackout date"]'));
    assert.deepEqual(current[0].config.blackout_dates, []);
    await type(blackout, '2026-12-25');
    assert.equal(blackout.value, '2026-12-25');
    assert.deepEqual(current[0].config.blackout_dates, []);
    await click(doc.querySelector('[aria-label="Add blackout date"]'));
    await type(blackout, '2026-12-25');
    await React.act(async () => blackout.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true })));
    assert.deepEqual(current[0].config.blackout_dates, ['2026-12-25']);
    await type(doc.querySelector('[aria-label="Active from"]')!, '2026-01-01T00:00');
    await click(doc.querySelector('[role="combobox"][aria-label="Schedule mode"]'));
    await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === 'once')!);
    form.triggers = current;
    for (const key of ['active_from', 'active_until', 'blackout_dates']) assert.equal(key in actionFormBody(form).triggers![0].config, false);
    // Reopen stored offset and fractional-second values, then edit an unrelated
    // field and serialize through the actual action model.
    const stored = { mode: 'once', timezone: 'Asia/Kolkata', run_at: '2026-12-01T03:30:12.123456789Z', active_from: '2026-11-01T09:00:00-04:00', active_until: '2027-01-01T00:00:00+00:00', blackout_dates: [] };
    let reopened: any = stored;
    const ScheduleEditor = (await import('../src/ui/components/actions/ScheduleEditor.tsx')).default;
    function Reopened({ initial = stored }: { initial?: any }) {
      const [config, setConfig] = React.useState<any>(initial);
      reopened = config;
      return React.createElement('form', {}, React.createElement(ScheduleEditor, { value: config, onChange: setConfig }));
    }
    await React.act(async () => root.render(React.createElement(Reopened)));
    assert.equal(reopened, stored);
    assert.equal((doc.querySelector('[aria-label="Once at"]') as HTMLInputElement).value, '2026-12-01T09:00:12.123');
    assert.ok(doc.querySelector('[role="alert"]')?.textContent?.includes('may prevent'));
    await type(doc.querySelector('[aria-label="Time zone"]')!, 'Asia/Kolkata');
    const reopenedForm = emptyActionForm();
    reopenedForm.triggers = [{ kind: 'schedule', config: reopened }] as any;
    const config = actionFormBody(reopenedForm).triggers![0].config;
    for (const key of ['run_at', 'active_from', 'active_until']) assert.equal(config[key], (stored as any)[key]);
    await type(doc.querySelector('[aria-label="Once at"]')!, '2028-12-01T09:00');
    assert.ok(doc.querySelector('[role="alert"]')?.textContent?.includes('will be skipped'));
    await click(doc.querySelector('[data-debug-id="action-schedule-once-clear-restrictions"]'));
    assert.equal(doc.querySelector('[role="alert"]'), null);
    for (const key of ['active_from', 'active_until', 'blackout_dates']) assert.equal(key in reopened, false);
    await click(doc.querySelector('[role="combobox"][aria-label="Schedule mode"]'));
    await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === 'cron')!);
    await type(doc.querySelector('[aria-label="Time zone"]')!, 'America/New_York');
    await type(doc.querySelector('[aria-label="Active from"]')!, '2026-03-08T02:30');
    assert.ok(doc.body.textContent?.includes('This time does not exist'));
    assert.equal(doc.querySelector('form')!.checkValidity(), false);
    await type(doc.querySelector('[aria-label="Active from"]')!, '');
    assert.equal(doc.querySelector('form')!.checkValidity(), true);
    // REQ-INTV-3/5: exact serialization, including fractional minutes.
    const chooseUnit = async (unit: string) => {
      await click(doc.querySelector('[aria-label="Interval unit"]'));
      await click(Array.from(doc.querySelectorAll('[role="option"]')).find(node => node.textContent === unit)!);
    };
    for (const [seconds, amount, unit] of [[60, '1', 'minutes'], [120, '2', 'minutes'], [3600, '1', 'hours'], [7200, '2', 'hours'], [86400, '1', 'days'], [90, '1.5', 'minutes'], [61, String(61 / 60), 'minutes']] as const) {
      await React.act(async () => root.render(React.createElement(Reopened, { key: 'interval-' + seconds, initial: { mode: 'interval', interval_s: seconds, timezone: 'UTC' } })));
      const interval = doc.querySelector('[aria-label="Interval"]') as HTMLInputElement;
      assert.equal(interval.value, amount);
      assert.equal(doc.querySelector('[aria-label="Interval unit"]')?.textContent?.includes(unit), true);
      await type(doc.querySelector('[aria-label="Time zone"]')!, 'Asia/Kolkata');
      await type(interval, amount);
      const form = emptyActionForm();
      form.triggers = [{ kind: 'schedule', config: reopened }] as any;
      assert.equal(actionFormBody(form).triggers![0].config.interval_s, seconds);
      for (const nextUnit of ['days', 'hours', 'minutes']) {
        await chooseUnit(nextUnit);
        assert.equal(reopened.interval_s, seconds);
        assert.equal(doc.querySelector('form')!.checkValidity(), true);
      }
    }
    // Conversion and bounds are expressed in the selected unit.
    for (const [unit, factor] of [['minutes', 60], ['hours', 3600], ['days', 86400]] as const) {
      await chooseUnit(unit);
      const interval = doc.querySelector('[aria-label="Interval"]') as HTMLInputElement;
      await type(interval, '2');
      assert.equal(reopened.interval_s, 2 * factor);
      assert.equal(doc.querySelector('form')!.checkValidity(), true);
      for (const invalid of ['', '0', String(31536000 / factor + 1), String(1.1 / factor)]) {
        await type(interval, invalid);
        assert.equal(doc.querySelector('form')!.checkValidity(), false);
        assert.ok(doc.body.textContent?.includes('Enter an interval'));
        assert.equal(reopened.interval_s, 2 * factor);
      }
      for (const boundary of [60, 31536000]) {
        await type(interval, String(boundary / factor));
        assert.equal(reopened.interval_s, boundary);
        assert.equal(doc.querySelector('form')!.checkValidity(), true);
      }
    }
    await chooseUnit('minutes');
    await type(doc.querySelector('[aria-label="Interval"]')!, '1.001');
    assert.equal(doc.querySelector('form')!.checkValidity(), false);
    assert.ok(doc.body.textContent?.includes('whole number of seconds'));
    // REQ-ONCEUI-2: compare instants for windows, and calendar dates in the
    // schedule zone for blackouts (this UTC instant is December 2 in Kolkata).
    const cases = [
      { active_from: '2026-12-01T20:00:01Z' },
      { active_until: '2026-12-01T19:59:59Z' },
      { blackout_dates: ['2026-12-02'] },
      { blackout_dates: ['2026-12-01'], safe: true },
      { active_from: '2026-12-01T20:00:00Z', active_until: '2026-12-01T20:00:00Z', safe: true },
    ];
    for (const [index, { safe, ...restrictions }] of cases.entries()) {
      const initial = { mode: 'once', timezone: 'Asia/Kolkata', run_at: '2026-12-01T20:00:00Z', ...restrictions };
      await React.act(async () => root.render(React.createElement(Reopened, { key: index, initial })));
      assert.ok(doc.querySelector('[role="alert"]')?.textContent?.includes(safe ? 'may prevent' : 'will be skipped'));
      for (const label of ['Active from', 'Active until', 'Blackout dates']) assert.equal(doc.querySelector('[aria-label="' + label + '"]'), null);
      await click(doc.querySelector('[data-debug-id="action-schedule-once-clear-restrictions"]'));
      const clearedForm = emptyActionForm();
      clearedForm.triggers = [{ kind: 'schedule', config: reopened }] as any;
      const cleared = actionFormBody(clearedForm).triggers![0].config;
      assert.equal(cleared.run_at, initial.run_at);
      assert.equal(cleared.timezone, initial.timezone);
      for (const key of ['active_from', 'active_until', 'blackout_dates']) assert.equal(key in cleared, false);
      assert.equal(doc.querySelector('[role="alert"]'), null);
    }

  } finally {
    if (root) await React.act(async () => root.unmount());
    dom.window.close();
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(g, name, descriptor);
      else delete g[name];
    }
  }
});
