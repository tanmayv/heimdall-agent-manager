import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { Provider } from 'react-redux';
import { makeVaultStore, installFetchCapture } from './helpers/vaultEndpointHarness.ts';
import { filterIssueFromError, filterSentence, measureFilter, replaceFilter, withinLimits } from '../src/ui/components/actions/filterTree.ts';
import type { FilterLimits, TriggerEvent } from '../src/ui/api/endpoints/actions.ts';
import { actionFormBody, emptyActionForm } from '../src/ui/components/actions/actionModel.ts';

const limits: FilterLimits = { max_depth: 4, max_nodes: 24, max_checks: 16, max_children: 16, max_values: 32, max_value_bytes: 256, max_field_bytes: 128, max_path_segments: 4, max_segment_bytes: 64, max_bytes: 4096 };
const event: TriggerEvent = { event_type: 'webhook.received', label: 'Webhook received', scope: 'webhook', no_delay: true, free_data_paths: true, fields: [], presets: [] };
const example = { all: [
  { field: 'data.action', op: 'in', value: ['opened', 'reopened'] },
  { any: [{ field: 'data.repo.name', op: 'prefix', value: 'heimdall-' }, { field: 'data.labels.urgent', op: 'exists', value: true }] },
  { not: { field: 'data.draft', op: 'eq', value: true } },
] } as const;

test('pointer edits preserve wrappers and use effective tree limits', () => {
  const tree = structuredClone(example) as any;
  assert.deepEqual(measureFilter(tree), { nodes: 7, checks: 4, depth: 3 });
  assert.equal(filterSentence(tree), 'action is one of opened, reopened AND (repo.name starts with "heimdall-" OR labels.urgent exists) AND NOT (draft is true)');
  assert.equal(withinLimits(tree, limits), true);
  assert.equal(withinLimits(tree, { ...limits, max_nodes: 6 }), false);
  assert.equal(withinLimits(tree, { ...limits, max_depth: 2 }), false);
  assert.equal(withinLimits(tree, { ...limits, max_checks: 3 }), false);
  const replaced = replaceFilter(tree, '/all/1/any/0', { field: 'actor', op: 'ne', value: 'hub' });
  assert.equal((replaced as any).all[1].any[0].field, 'actor');
  assert.equal(tree.all[1].any[0].field, 'data.repo.name');
  assert.deepEqual(replaceFilter({ not: { any: [{ field: 'actor', op: 'eq', value: 'hub' }] } }, '/not/any/0', null), {});
  assert.deepEqual(filterIssueFromError({ data: { details: JSON.stringify({ code: 'invalid_filter', path: '/all/1/any/0', reason: 'bad_value' }) } }), { path: '/all/1/any/0', reason: 'bad_value' });
  const form = emptyActionForm();
  form.triggers = [{ kind: 'event', enabled: true, delay_s: 42, config: { event_type: 'webhook.received', filter: tree } }];
  assert.equal(actionFormBody(form).triggers![0].delay_s, 0);
});

test('build the spec example through controls; show exact path errors, limits, undo and full test trace', async () => {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const g = globalThis as any;
  const names = ['window', 'document', 'HTMLElement', 'HTMLInputElement', 'HTMLTextAreaElement', 'Node', 'getComputedStyle', 'requestAnimationFrame', 'cancelAnimationFrame', 'IS_REACT_ACT_ENVIRONMENT', 'CSS'];
  const previous = new Map(names.map(name => [name, Object.getOwnPropertyDescriptor(g, name)]));
  for (const name of names) Object.defineProperty(g, name, { configurable: true, writable: true, value: name === 'IS_REACT_ACT_ENVIRONMENT' ? true : (dom.window as any)[name] });
  g.CSS = { escape: (v: string) => v.replace(/[^a-zA-Z0-9_-]/g, char => '\\' + char) };
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  const store = await makeVaultStore();
  const originalFetch = globalThis.fetch;
  const capture = installFetchCapture();
  let root: any;
  try {
    const { createRoot } = await import('react-dom/client');
    const Editor = (await import('../src/ui/components/actions/ConditionTreeEditor.tsx')).default;
    let current: any = {};
    let setTree: (v: any) => void;
    let issue: any;
    let effective = limits;
    function Harness() {
      const [value, setValue] = React.useState<any>({}); current = value; setTree = setValue;
      return React.createElement(Editor, { value, onChange: setValue, event, limits: effective, debugId: 'test', error: issue });
    }
    root = createRoot(dom.window.document.getElementById('root')!);
    const render = () => root.render(React.createElement(Provider, { store, children: React.createElement(Harness) }));
    await React.act(async () => render());
    const doc = dom.window.document;
    const byId = (id: string) => doc.querySelector('[data-debug-id="' + id + '"]')!;
    const click = async (node: Element) => { assert.ok(node); await React.act(async () => node.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true }))); };
    const type = async (node: Element, value: string) => {
      assert.ok(node);
      await React.act(async () => {
        const proto = node.tagName === 'TEXTAREA' ? dom.window.HTMLTextAreaElement.prototype : dom.window.HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value')!.set!.call(node, value);
        node.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
      });
    };
    const select = async (id: string, text: string) => {
      await click(byId(id));
      const option = Array.from(doc.querySelectorAll('[role="option"]')).find(n => n.textContent === text);
      assert.ok(option, text); await click(option);
    };
    await click(byId('test-add-first-check'));
    await type(byId('test-node--all-0-field'), 'data.action');
    await select('test-node--all-0-operator', 'is one of');
    await type(byId('test-node--all-0-item-0-value'), 'opened');
    await click(byId('test-node--all-0-add-value'));
    await type(byId('test-node--all-0-item-1-value'), 'reopened');
    await click(byId('test-node-root-add-group'));
    await select('test-node--all-1-mode', 'Any of');
    await type(byId('test-node--all-1-any-0-field'), 'data.repo.name');
    await select('test-node--all-1-any-0-operator', 'starts with');
    await type(byId('test-node--all-1-any-0-value'), 'heimdall-');
    await click(byId('test-node--all-1-add-check'));
    await type(byId('test-node--all-1-any-1-field'), 'data.labels.urgent');
    await select('test-node--all-1-any-1-operator', 'exists');
    await click(byId('test-node-root-add-check'));
    await type(byId('test-node--all-2-field'), 'data.draft');
    await select('test-node--all-2-value-type', 'boolean');
    await click(byId('test-node--all-2-negate'));
    assert.deepEqual(current, example);
    assert.ok(doc.body.textContent?.includes('In words:'));
    // Equivalent nested-group semantics: named fieldsets, native tab controls.
    assert.ok(doc.querySelector('fieldset[data-node-path=""]'));
    assert.ok(doc.querySelector('fieldset[data-node-path="/all/1/any/0"]'));
    assert.equal(Array.from(doc.querySelectorAll('fieldset')).some(el => el.getAttribute('aria-label')?.includes('/all')), false);
    issue = { path: '/all/1/any/0', reason: 'bad_value' };
    await React.act(async () => render());
    assert.equal(doc.querySelectorAll('[data-node-path][aria-invalid="true"]').length, 1);
    assert.equal(doc.querySelector('[data-node-path][aria-invalid="true"]')?.getAttribute('data-node-path'), issue.path);
    issue = undefined;
    effective = { ...limits, max_nodes: 7 };
    await React.act(async () => render());
    assert.equal((byId('test-node-root-add-check') as HTMLButtonElement).disabled, true);
    assert.equal((byId('test-node-root-add-group') as HTMLButtonElement).disabled, true);
    effective = { ...limits, max_depth: 3 };
    await React.act(async () => render());
    assert.equal((byId('test-node--all-1-add-group') as HTMLButtonElement).disabled, true);
    effective = limits;
    await React.act(async () => render());
    await click(byId('test-node--all-1-any-0-remove'));
    assert.equal(doc.activeElement, byId('test-undo'));
    assert.equal(byId('test-undo').parentElement?.getAttribute('role'), 'status');
    await click(byId('test-undo'));
    assert.deepEqual(current, example);
    assert.equal(doc.activeElement, byId('test-node--all-1-any-0-field'));
    await click(byId('test-node--all-1-collapse'));
    assert.equal(byId('test-node--all-1-collapse').getAttribute('aria-expanded'), 'false');
    assert.ok(byId('test-node--all-1-collapse').textContent?.includes('Any of 2 checks'));
    await click(byId('test-view-tree'));
    assert.equal(doc.querySelectorAll('[role="treeitem"]').length, 7);
    const rootNode = byId('test-diagram-node-root');
    await React.act(async () => rootNode.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true })));
    assert.equal(doc.activeElement?.getAttribute('data-tree-path'), '/all/0');
    await click(byId('test-diagram-node--all-1-any-0'));
    assert.equal(doc.activeElement, byId('test-node--all-1-any-0-field'));
    assert.equal(byId('test-node--all-1-collapse').getAttribute('aria-expanded'), 'true');
    await click(byId('test-sample-toggle'));
    await type(byId('test-sample'), 'not JSON');
    await click(byId('test-test'));
    assert.ok(doc.body.textContent?.includes('Enter valid JSON'));
    await type(byId('test-sample'), '{"action":"opened"}');
    capture.setNextResponse({ data: { valid: true, matched: false, nodes: 'FFTFTFT', path: '', reason: '' } });
    await click(byId('test-test'));
    assert.ok(doc.body.textContent?.includes('Sample does not match'));
    const result = doc.querySelector('[aria-label="Condition test results"]');
    assert.equal(result?.querySelectorAll('li').length, 7);
    assert.ok(result?.querySelector('[role="treeitem"][aria-label*="action is one of"][aria-label*="Did not match"]'));
    const testRequest = capture.requests.find(c => c.url.includes('/actions/filter-test'));
    assert.ok(testRequest);
    assert.deepEqual(testRequest.body.filter, example);
    await React.act(async () => setTree!({ not: { any: [{ field: 'actor', op: 'eq', value: 'hub' }] } }));
    assert.ok(doc.body.textContent?.includes('None of'));
    await React.act(async () => setTree!({}));
    assert.ok(doc.body.textContent?.includes('Always'));
  } finally {
    if (root) await React.act(async () => root.unmount());
    store.dispatch((await import('../src/ui/api/endpoints/actions.ts')).actionsApi.util.resetApiState());
    await new Promise(resolve => dom.window.setTimeout(resolve, 40));
    globalThis.fetch = originalFetch;
    for (const name of names) { const descriptor = previous.get(name); if (descriptor) Object.defineProperty(g, name, descriptor); else delete g[name]; }
    dom.window.close();
  }
});

test('reusable diagram collapses None-of wire wrapper without shifting trace indices', async () => {
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { JSDOM } = await import('jsdom');
  const Tree = (await import('../src/ui/components/actions/ConditionTree.tsx')).default;
  const html = renderToStaticMarkup(React.createElement(Tree, { value: { not: { any: [{ field: 'data.a', op: 'eq', value: 'one' }, { field: 'data.b', op: 'eq', value: 'two' }] } }, trace: 'TFFT', debugId: 'trace' }));
  const dom = new JSDOM(html);
  try {
    const doc = dom.window.document;
    assert.equal(doc.querySelectorAll('[role="treeitem"]').length, 3);
    assert.match(doc.querySelector('[data-tree-path=""]')!.getAttribute('aria-label')!, /None of 2 checks.*Matched/);
    assert.match(doc.querySelector('[data-tree-path="/not/any/0"]')!.getAttribute('aria-label')!, /Did not match/);
    assert.match(doc.querySelector('[data-tree-path="/not/any/1"]')!.getAttribute('aria-label')!, /Matched/);
    assert.equal(doc.querySelector('[role="group"]')?.parentElement?.getAttribute('role'), 'treeitem');
    assert.equal(doc.querySelectorAll('[tabindex="0"]').length, 1);
  } finally { dom.window.close(); }
});
