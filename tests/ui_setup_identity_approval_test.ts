// Real IdentityStep with deferred enrollment, isolated from native/API mutations.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import React from 'react';
import { createRoot } from 'react-dom/client';
import { JSDOM } from 'jsdom';

const calls: string[] = [];
const lookups: string[] = [];
let progress: (message: string) => void;
let resolveApproval: (value: any) => void;
let rejectApproval: (error: Error) => void;
const fixture = {
  entitlements: () => ({ max_bridges: 10 }),
  bridges: () => ({ data: { bridges: [] }, refetch: () => ({ unwrap: async () => ({ bridges: [] }) }) }),
  lookup: async (code: string) => {
    lookups.push(code);
    return { info: { code }, keys: {}, label: code, fingerprint: code, hubOrigin: 'https://hub.test' };
  },
  approve: (options: any) => {
    calls.push(options.info.code);
    progress = options.onProgress;
    return new Promise((resolve, reject) => { resolveApproval = resolve; rejectApproval = reject; });
  },
};
(globalThis as any).__identityFixture = fixture;
const stubs: Record<string, string> = {
  '../../hooks/useEntitlements': 'export const useEntitlements = globalThis.__identityFixture.entitlements;',
  '../../api/endpoints/bridgeSupport': 'export const useListBridgesQuery = globalThis.__identityFixture.bridges;',
  '../../api/endpoints/bridges': 'export const fetchPendingBridgeEnrollments = async () => [];',
  '../../services/deviceVault': "export const deviceVaultUserId = () => 'fixture';",
  '../devices/DeviceApprovalPage': `export const lookUpPairing = globalThis.__identityFixture.lookup;
    export const BridgeReconnectWait = () => 'Reconnect original approval';`,
  '../devices/bridgeApproval': 'export const approveBridgeEnrollment = globalThis.__identityFixture.approve;',
};
registerHooks({ resolve(specifier, context, next) {
  if (context.parentURL?.includes('/setup/SetupWizardPage.tsx') && stubs[specifier]) {
    return { url: 'data:text/javascript,' + encodeURIComponent(stubs[specifier]), shortCircuit: true };
  }
  return next(specifier, context);
} });

test('replacement codes serialize behind the owning approval on success and failure', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.test/#/setup' });
  const previous = { window: globalThis.window, document: globalThis.document, act: (globalThis as any).IS_REACT_ACT_ENVIRONMENT };
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });
  const { IdentityStep } = await import('../src/ui/components/setup/SetupWizardPage.tsx');
  const { openApprovalForCode, overrideApprovalPageOpener } = await import('../src/ui/bridge/desktopBridgeSession.ts');
  const restore = overrideApprovalPageOpener(() => {});
  const root = createRoot(dom.window.document.getElementById('root')!);
  const find = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLButtonElement;
  const click = async () => { await React.act(async () => find('setup-identity-approve-btn').click()); };
  const code = async (value: string) => { await React.act(async () => openApprovalForCode(value)); };
  const mount = async (key: number) => { await React.act(async () => root.render(React.createElement(IdentityStep, { key, onDone() {}, onBack() {} }))); };
  try {
    await code('A');
    await mount(1);
    // Two clicks in one render must still start only one signing/POST sequence.
    await React.act(async () => { find('setup-identity-approve-btn').click(); find('setup-identity-approve-btn').click(); });
    assert.deepEqual(calls, ['A']);
    await code('B');
    assert.equal(find('setup-identity-approve-btn').disabled, true);
    assert.deepEqual(lookups, ['A'], 'replacement is not looked up during committed work');
    await React.act(async () => progress('Delivering original keyring'));
    assert.match(find('setup-identity-progress').textContent!, /original keyring/);
    await click();
    assert.deepEqual(calls, ['A']);
    await React.act(async () => resolveApproval({ bridgeId: 'brg_A', label: 'A', approved: 'Approved A' }));
    assert.match(find('setup-identity-outcome').textContent!, /Approved A/);
    await React.act(async () => progress('LATE A'));
    assert.match(find('setup-identity-outcome').textContent!, /Approved A/, 'settled progress cannot leave reconnect');
    await code('C');
    assert.match(find('setup-identity-outcome').textContent!, /Approved A/, 'reconnect keeps ownership');
    assert.deepEqual(lookups, ['A']);

    await mount(2);
    await code('D');
    await click();
    const staleProgress = progress!;
    await code('E');
    await code('F');
    assert.deepEqual(calls, ['A', 'D']);
    await React.act(async () => rejectApproval(new Error('D failed')));
    assert.deepEqual(lookups, ['A', 'D', 'F'], 'only the latest queued request is reviewed after failure');
    assert.match(find('setup-identity-error').textContent!, /D failed.*latest pairing request/);
    assert.equal(find('setup-identity-approve-btn').disabled, false);
    await click();
    await React.act(async () => staleProgress('STALE D'));
    assert.doesNotMatch(find('setup-identity-progress').textContent!, /STALE/);
    assert.deepEqual(calls, ['A', 'D', 'F']);
    await React.act(async () => root.unmount());
    await React.act(async () => resolveApproval({ bridgeId: 'brg_F', label: 'F', approved: 'Approved F' }));
  } finally {
    await React.act(async () => root.unmount());
    restore();
    Object.assign(globalThis, { window: previous.window, document: previous.document, IS_REACT_ACT_ENVIRONMENT: previous.act });
    delete (globalThis as any).__identityFixture;
    dom.window.close();
  }
});
