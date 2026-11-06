// Synthetic accounts, credentials and databases only, supplied by disposable harness.
import { createDeviceIdentity, memoryDeviceStore } from '../../src/ui/utils/deviceIdentity.ts';
import { generatePairCode, generatePairSalt, derivePairKeys, pairHubOrigin } from '../../src/ui/utils/vaultPairing.ts';
import { buildPairedRegistration, checkBrowserCodeInfo, buildBrowserApproval, buildRevocation } from '../../src/ui/utils/vaultDeviceFlows.ts';
import { signedRequestHeaders } from '../../src/ui/utils/vaultRequestSigner.ts';
import { decryptVaultText } from '../../src/ui/utils/vaultContent.ts';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { prepareOwnerOperation, sendOwnerOperation, ownerId, ownerRelayFile } from '../../src/ui/api/ownerLocalClient.ts';

export async function ownerRegistryFlow({hub, approver, bridgeId, http, expect, registryFixture, rekeyOwner}: any) {
  const send = async (body: unknown) => {
    const response = await http(hub, 'POST', '/api/v1/owner-local/relay', {body});
    if (response.status !== 200) throw new Error(response.raw);
    return response.data;
  };
  const rootSession = {identity: approver.identity, chain: await approver.chain(), keyring: await importKeyring(Uint8Array.from(approver.keyringBytes), approver.userId)};
  const cid = ownerId('chain_');
  const invoke = async (session: any, method: any, input: any) => sendOwnerOperation(session, await prepareOwnerOperation(session, bridgeId, method, input), send);
  await invoke(rootSession, 'chain.create', {chainId: cid, expectedRevision: '0', title: 'Registry page chain', description: ''});
  for (let i = 1; i <= 105; i++) await invoke(rootSession, 'task.create', {
    chainId: cid, taskId: 'task_registry_' + String(i).padStart(3, '0'), expectedRevision: String(i), title: 'Registry task ' + i, body: '',
  });
  const {listOwnerRegistryPages} = await import('../../src/ui/api/ownerRegistryListing.ts');
  const fetchPage = async (path: string) => {
    const response = await http(hub, 'GET', path);
    expect(response.status === 200, 'real registry page accepted');
    return response.data;
  };
  let rows = await listOwnerRegistryPages(fetchPage, () => true);
  expect(rows.filter(r => r.chain_id === cid).length === 106, 'real HTTP registry exposes header plus all 105 live tasks');
  const renderListing = async (count: number) => {
    const {JSDOM} = await import('jsdom');
    const React = await import('react');
    const {installKeyringFromWrap, clearKeyringSession} = await import('../../src/ui/utils/vaultKeyringSession.ts');
    const {sessionHeaders} = await import('./hubOidc.mjs');
    const {default: OwnerLocalPanel} = await import('../../src/ui/components/taskchain/OwnerLocalPanel.tsx');
    await installKeyringFromWrap(approver.identity, approver.wrap, await approver.chain());
    const dom = new JSDOM('<div id="root"></div>', {url: hub.base});
    const keys = ['window', 'document', 'navigator', 'HTMLElement', 'IS_REACT_ACT_ENVIRONMENT'];
    const saved = keys.map(k => Object.getOwnPropertyDescriptor(globalThis, k));
    for (const [key, value] of Object.entries({window:dom.window, document:dom.window.document, navigator:dom.window.navigator, HTMLElement:dom.window.HTMLElement, IS_REACT_ACT_ENVIRONMENT:true}))
      Object.defineProperty(globalThis, key, {value, configurable:true, writable:true});
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (url: any, init: any = {}) => originalFetch(new URL(String(url), hub.base), {
      ...init, headers: {...Object.fromEntries(new Headers(sessionHeaders(hub.session, hub.base))), ...Object.fromEntries(new Headers(init.headers))},
    });
    const {createRoot} = await import('react-dom/client');
    const root = createRoot(dom.window.document.getElementById('root')!);
    try {
      await React.act(async () => root.render(React.createElement(OwnerLocalPanel, {onClose: () => {}})));
      await React.act(async () => (dom.window.document.querySelector('[data-debug-id="owner-local-list"]') as HTMLElement).click());
      for (const deadline = Date.now() + 20000;;) {
        const visible = dom.window.document.querySelectorAll('[data-debug-id^="owner-local-select-' + cid + '"]');
        if (visible.length === count) break;
        if (Date.now() > deadline) throw new Error('Registry panel did not settle: ' + dom.window.document.body.textContent);
        await React.act(async () => { await new Promise(r => setTimeout(r, 50)); });
      }
      expect(!!dom.window.document.querySelector('[data-debug-id="owner-local-select-' + cid + 'task_registry_105"]'), 'rendered production panel reaches task 105 with ' + count + ' visible rows');
    } finally {
      await React.act(async () => root.unmount()); globalThis.fetch = originalFetch; clearKeyringSession(); dom.window.close();
      keys.forEach((k,i) => {if (saved[i]) Object.defineProperty(globalThis,k,saved[i]!); else delete (globalThis as any)[k];});
    }
  };
  await renderListing(106);
  for (let i = 1; i <= 104; i++) await invoke(rootSession, 'task.delete', {
    chainId: cid, taskId: 'task_registry_' + String(i).padStart(3, '0'), expectedRevision: '1',
  });
  rows = await listOwnerRegistryPages(fetchPage, () => true);
  expect(rows.filter(r => r.chain_id === cid).length === 2, 'real HTTP registry traverses 104 tombstones to surviving task 105');
  await renderListing(2);

  // Add creator and backup browsers through the actual signed directory API.
  const addBrowser = async (label: string) => {
    const identity = await createDeviceIdentity(memoryDeviceStore(), approver.userId);
    const salt = generatePairSalt();
    const keys = await derivePairKeys(generatePairCode(), {kind:'browser', userId:approver.userId, hubOrigin:pairHubOrigin(hub.base), pairSalt:salt});
    const reg = await buildPairedRegistration(identity, label, keys);
    const registered = await http(hub, 'POST', '/api/v1/vault/devices/register', {body: {
      statement:reg.statement, proof_signature:reg.signature, pair_lookup:reg.pairLookup, pair_key_mac:reg.pairKeyMac, pair_salt:salt, pair_hub_origin:pairHubOrigin(hub.base),
    }});
    expect(registered.status === 201 || registered.status === 200, 'registered synthetic ' + label);
    const verified = await http(hub, 'POST', '/api/v1/device/verify', {body:{pair_lookups:[keys.lookup]}});
    const paired = await checkBrowserCodeInfo(verified.data, keys, approver.userId);
    const approval = await buildBrowserApproval(approver.identity, await approver.chain(), paired, keys, label, approver.keyringBytes);
    const approved = await http(hub, 'POST', '/api/v1/vault/devices/' + identity.deviceId + '/approve', {
      body:approval, headers:await signedRequestHeaders(approver.identity, approver.userId, 'POST', '/api/v1/vault/devices/' + identity.deviceId + '/approve', JSON.stringify(approval)),
    });
    expect(approved.status === 200, 'approved synthetic ' + label + ': ' + approved.status);
    return identity;
  };
  const creator = await addBrowser('registry creator');
  await addBrowser('registry backup');
  const creatorSession = {...rootSession, identity:creator, chain:await approver.chain()};
  const boundChain = ownerId('chain_'), unregisteredChain = ownerId('chain_');
  await invoke(creatorSession, 'chain.create', {chainId:boundChain, expectedRevision:'0', title:'Before creator revoke', description:''});
  const beforeEdit = (await listOwnerRegistryPages(fetchPage, () => true)).find(r => r.chain_id === boundChain && !r.task_id)!;
  const beforeRevision = BigInt(JSON.parse(beforeEdit.registry_json).metadata_revision);
  await registryFixture('save', boundChain);
  await invoke(creatorSession, 'chain.edit', {chainId:boundChain, expectedRevision:'1', title:'After creator revoke', description:''});
  await invoke(creatorSession, 'chain.create', {chainId:unregisteredChain, expectedRevision:'0', title:'Delayed first publication', description:''});
  const historicalOp = await prepareOwnerOperation(creatorSession, bridgeId, 'chain.edit', {chainId:boundChain, expectedRevision:'2', title:'revoked command', description:''});
  const historicalRelay = await ownerRelayFile(creatorSession, historicalOp);
  await registryFixture('rewind', boundChain);
  await registryFixture('unregister', unregisteredChain);
  const {body, nextKeyring} = await buildRevocation(approver.identity, await approver.chain(), creator.deviceId, approver.keyringBytes);
  const revokePath = '/api/v1/vault/devices/' + creator.deviceId + '/revoke';
  const revoked = await http(hub, 'POST', revokePath, {body, headers:await signedRequestHeaders(approver.identity, approver.userId, 'POST', revokePath, JSON.stringify(body))});
  expect(revoked.status === 200, 'signed synthetic creator revocation accepted');
  approver.keyringBytes = nextKeyring;
  await rekeyOwner();
  expect((await registryFixture('publish', boundChain)).status === 200, 'current owner publishes newer bound metadata after creator revocation through real HTTP');
  rows = await listOwnerRegistryPages(fetchPage, () => true);
  const published = JSON.parse(rows.find(r => r.chain_id === boundChain && !r.task_id)!.registry_json);
  expect(BigInt(published.metadata_revision) > beforeRevision && await decryptVaultText(published.chain_title_cipher, rootSession.keyring) === 'After creator revoke', 'newer committed title is discoverable after creator revocation');
  expect((await registryFixture('publish', unregisteredChain)).status === 403, 'valid signed but unregistered genesis fails closed after creator revocation');
  let denied = false;
  try { await sendOwnerOperation(creatorSession, historicalOp, async () => send(historicalRelay)); } catch { denied = true; }
  expect(denied, 'revoked creator signed command rejected through actual owner relay');
}
