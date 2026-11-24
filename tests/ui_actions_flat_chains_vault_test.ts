import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { Provider } from 'react-redux';
import { installFetchCapture, installWindowShim, makeVaultStore, unlockVault, clearActiveKey } from './helpers/vaultEndpointHarness.ts';

const { taskChainsApi } = await import('../src/ui/api/endpoints/taskChains.ts');
const { vaultCacheInvalidationMiddleware } = await import('../src/ui/api/vaultCacheInvalidation.ts');
const { encryptVaultText } = await import('../src/ui/utils/vaultContent.ts');
const { default: EventTriggerEditor } = await import('../src/ui/components/actions/EventTriggerEditor.tsx');
const KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

for (const wrapped of [false, true]) {
  test(`flat chains decrypt after unlock and render plaintext action selector labels (wrapped=${wrapped})`, async () => {
    installWindowShim();
    const capture = installFetchCapture();
    const store = await makeVaultStore({ extraMiddleware: [vaultCacheInvalidationMiddleware] });
    try {
      const key = await unlockVault(store, KEY);
      const title = await encryptVaultText('Release automation', key);
      const project = await encryptVaultText('Private project', key);
      const rows = [{ chain_id: 'chain_secret', title, project_name: project, projectName: project }, { chain_id: 'chain_plain', title: 'Public chain' }];
      const response = wrapped ? { chains: rows, total: 2 } : rows;
      capture.setNextResponse({ data: response });
      store.dispatch((await import('../src/ui/store/vaultSlice.ts')).keyringCleared());
      const locked = store.dispatch(taskChainsApi.endpoints.listFlatTaskChains.initiate());
      assert.deepEqual(await locked.unwrap(), response);
      locked.unsubscribe();
      await unlockVault(store, KEY);
      assert.equal(taskChainsApi.endpoints.listFlatTaskChains.select()(store.getState()).status, 'uninitialized');
      const query = store.dispatch(taskChainsApi.endpoints.listFlatTaskChains.initiate());
      const result = await query.unwrap();
      const chains = wrapped ? result.chains : result;
      assert.equal(chains[0].title, 'Release automation');
      assert.equal(chains[0].project_name, 'Private project');
      assert.equal(chains[0].projectName, 'Private project');
      assert.equal(chains[1].title, 'Public chain');
      assert.equal(rows[0].title, title, 'wire data stays encrypted');
      if (wrapped) assert.equal(result.total, 2);
      const html = renderToStaticMarkup(React.createElement(Provider, { store, children: React.createElement(EventTriggerEditor, {
        value: { event_type: 'chain.state', chain_id: 'chain_secret', data: {} }, events: [], onChange() {}, debugId: 'test-event',
      }) }));
      assert.match(html, /Release automation/);
      assert.doesNotMatch(html, /vault:v2:/);
      assert.equal(capture.requests.length, 2, 'unlock requires a fresh fetch');
      assert.match(capture.requests[0].url, /flat=1/);
      query.unsubscribe();
    } finally {
      store.dispatch(taskChainsApi.util.resetApiState());
      await clearActiveKey();
    }
  });
}
