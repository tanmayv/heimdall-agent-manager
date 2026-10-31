// Exercise the shell's actual redirect hook without loading unrelated shell feeds.
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_setup_redirect_test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { createRoot } from 'react-dom/client';
import { JSDOM } from 'jsdom';

const { useSetupRedirect } = await import('../src/ui/components/setup/useSetupRedirect.ts');
const { markSetupSeen } = await import('../src/ui/components/setup/setupWizardModel.ts');

test('launch redirect is desktop-only, account-scoped and checks the initial route once', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/#/home' });
  const previous = { window: globalThis.window, document: globalThis.document, act: (globalThis as any).IS_REACT_ACT_ENVIRONMENT };
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  const root = createRoot(dom.window.document.getElementById('root')!);
  function Launch({ path, userId }: { path: string; userId: string }) {
    useSetupRedirect(path, userId);
    return null;
  }
  let mount = 0;
  const render = async (path: string, userId: string, fresh = true) => {
    if (fresh) mount++;
    await React.act(async () => { root.render(React.createElement(Launch, { key: mount, path, userId })); });
  };
  try {
    await render('/home', 'a');
    assert.equal(dom.window.location.hash, '#/home', 'browser launch stays home');
    (dom.window as any).odinApi = {};
    await render('/home', 'a');
    assert.equal(dom.window.location.hash, '#/setup');
    dom.window.location.hash = '#/home';
    await render('/home', 'a', false);
    assert.equal(dom.window.location.hash, '#/home', 'returning home cannot redirect again');
    markSetupSeen('a');
    await render('/home', 'a');
    assert.equal(dom.window.location.hash, '#/home', 'finished/skipped account stays home on next launch');
    await render('/home', 'b');
    assert.equal(dom.window.location.hash, '#/setup', 'a different account still receives setup');
    dom.window.location.hash = '#/device/add';
    await render('/device/add', 'b');
    assert.equal(dom.window.location.hash, '#/device/add', 'launch deep link is preserved');
    dom.window.location.hash = '#/home';
    await render('/home', 'b', false);
    assert.equal(dom.window.location.hash, '#/home', 'later navigation cannot replace the launch destination');
    await render('/home', '');
    assert.equal(dom.window.location.hash, '#/home', 'no account never redirects');
  } finally {
    await React.act(async () => root.unmount());
    globalThis.window = previous.window;
    globalThis.document = previous.document;
    (globalThis as any).IS_REACT_ACT_ENVIRONMENT = previous.act;
    dom.window.close();
  }
});
