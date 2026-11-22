// Artifact image previews (review-card screenshots, chat/comment attachments, Library
// thumbnails) decrypt vault-sealed content bytes before display and never surface
// ciphertext. The hub serves an encrypted artifact's stored `vault:v2:` token as the
// body with the artifact's image Content-Type; making an object URL from that painted
// the <img> alt (the sealed name) as raw `vault:v2:…` text in every thumbnail.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_artifact_preview_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { importKeyring, serializeKeyringBytes } from '../src/ui/utils/vaultKeyring.ts';
import { encryptVaultBytes, encryptVaultText, VAULT_LOCKED_MARKER } from '../src/ui/utils/vaultCrypto.ts';
import { openArtifactContentBlob, safeArtifactAltText } from '../src/ui/utils/artifactContentVault.ts';

const KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const OTHER_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const ARMOR = 'vault:v2:';
// A PNG signature plus bytes that are invalid UTF-8: a text round-trip would corrupt them.
const PNG = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0xfe, 0x00, 0x80, 0xc3, 0x28]);

async function bytesOf(blob: Blob): Promise<number[]> {
  return [...new Uint8Array(await blob.arrayBuffer())];
}

test('encrypted image bytes decrypt byte-for-byte and keep the served content type', async () => {
  const key = await keyringFromHex(KEY_HEX);
  const served = new Blob([await encryptVaultBytes(PNG, key)], { type: 'image/png' });
  const opened = await openArtifactContentBlob(served, key);
  assert.equal(opened.locked, false);
  assert.equal(opened.lockReason, '');
  assert.equal(opened.blob.type, 'image/png');
  assert.deepEqual(await bytesOf(opened.blob), [...PNG]);
});

test('plaintext content passes through untouched; malformed armor fails closed', async () => {
  const key = await keyringFromHex(KEY_HEX);
  const png = new Blob([PNG], { type: 'image/png' });
  const opened = await openArtifactContentBlob(png, key);
  assert.equal(opened.blob, png);
  assert.equal(opened.locked, false);
  const text = new Blob(['plain notes'], { type: 'text/plain' });
  assert.equal((await openArtifactContentBlob(text, null)).blob, text);
  assert.equal((await openArtifactContentBlob(text, null)).locked, false);
  const malformed = await openArtifactContentBlob(new Blob(['vault:v2: not a token'], { type: 'image/png' }), key);
  assert.equal(malformed.locked, true);
});

test('locked vault, another vault, a wrong key and a forged token report locked and never yield plaintext', async () => {
  const key = await keyringFromHex(KEY_HEX);
  const armored = await encryptVaultBytes(PNG, key);
  const served = new Blob([armored], { type: 'image/png' });
  const expectSealed = async (keyring: any, reason: string) => {
    const opened = await openArtifactContentBlob(served, keyring);
    assert.equal(opened.locked, true);
    assert.equal(opened.lockReason, reason);
    assert.equal(opened.blob, served, 'only the fetched ciphertext is returned; callers must not display it');
  };
  await expectSealed(null, 'locked');
  const otherVaultKey = Uint8Array.from(Buffer.from(OTHER_KEY_HEX, 'hex'));
  await expectSealed(await importKeyring(serializeKeyringBytes({ userId: 'usr_test', vaultId: '7e57000000000002', currentEpoch: 1, entries: [{ epoch: 1, key: otherVaultKey }] })), 'other_vault');
  // Same vault id, wrong key: the token does not authenticate.
  await expectSealed(await keyringFromHex(OTHER_KEY_HEX), 'locked');
  const tampered = armored.slice(0, -4) + (armored.endsWith('AAAA') ? 'BBBB' : 'AAAA');
  const forged = await openArtifactContentBlob(new Blob([tampered], { type: 'image/png' }), key);
  assert.equal(forged.locked, true);
  assert.equal(forged.lockReason, 'locked');
});

test('alt text is the plaintext name or the fallback, never ciphertext or a lock marker', async () => {
  const key = await keyringFromHex(KEY_HEX);
  const sealed = await encryptVaultText('login.png', key);
  assert.equal(safeArtifactAltText('login.png', 'Screenshot 1'), 'login.png');
  assert.equal(safeArtifactAltText(sealed, 'Screenshot 1'), 'Screenshot 1');
  assert.equal(safeArtifactAltText(`shot ${sealed}`, 'Screenshot 1'), 'Screenshot 1');
  assert.equal(safeArtifactAltText(VAULT_LOCKED_MARKER, 'Screenshot 1'), 'Screenshot 1');
  assert.equal(safeArtifactAltText('', 'Screenshot 1'), 'Screenshot 1');
  assert.equal(safeArtifactAltText(undefined, 'Screenshot 1'), 'Screenshot 1');
});

test('image detection ignores a sealed name and relies on kind/mime', async () => {
  const { isArtifactImage } = await import('../src/ui/components/ArtifactAttachmentPreview.tsx');
  const key = await keyringFromHex(KEY_HEX);
  const sealed = await encryptVaultText('notes.txt', key);
  assert.equal(isArtifactImage({ name: `${sealed}.png` }), false);
  assert.equal(isArtifactImage({ name: sealed, mime: 'image/png' }), true);
  assert.equal(isArtifactImage({ name: 'plain.webp' }), true);
});

test('ArtifactAttachmentPreview shows a locked placeholder, then the decrypted image after unlock', async () => {
  const React = await import('react');
  const { act } = React;
  const { JSDOM } = await import('jsdom');
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { makeVaultStore, unlockVault, lockVaultFully } = await import('./helpers/vaultEndpointHarness.ts');
  const { ArtifactAttachmentPreview, ArtifactImagePreview } = await import('../src/ui/components/ArtifactAttachmentPreview.tsx');

  const key = await keyringFromHex(KEY_HEX);
  const sealedName = await encryptVaultText('checkout-flow.png', key);
  const armoredBody = await encryptVaultBytes(PNG, key);

  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const saved: any = {};
  for (const k of ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT']) saved[k] = (globalThis as any)[k];
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true });
  const previousFetch = globalThis.fetch;
  const previousCreate = URL.createObjectURL;
  const previousRevoke = URL.revokeObjectURL;
  const madeFrom = new Map<string, Blob>();
  let nextUrl = 0;
  URL.createObjectURL = ((blob: Blob) => { const url = `blob:test/${nextUrl += 1}`; madeFrom.set(url, blob); return url; }) as any;
  URL.revokeObjectURL = (() => {}) as any;
  globalThis.fetch = (async (input: any) => {
    assert.match(String(input), /\/api\/v1\/artifacts\/art_shot\/content$/);
    return { ok: true, status: 200, blob: async () => new Blob([armoredBody], { type: 'image/png' }) };
  }) as any;

  const store = await makeVaultStore();
  await lockVaultFully(store);
  const root = createRoot(dom.window.document.getElementById('root')!);
  const doc = dom.window.document;
  const artifact = { artifact_id: 'art_shot', name: sealedName, mime: 'image/png' };
  const session = { daemonUrl: '', clientToken: 'v1' };
  const settle = async (done: () => boolean) => {
    for (let i = 0; i < 100 && !done(); i += 1) await act(async () => { await new Promise((r) => setTimeout(r, 5)); });
  };
  const assertNoCiphertext = () => {
    assert.ok(!doc.body.innerHTML.includes(ARMOR), doc.body.innerHTML);
    for (const img of doc.querySelectorAll('img')) assert.ok(!String(img.getAttribute('alt')).includes(ARMOR));
  };
  try {
    await act(async () => {
      root.render(React.createElement(Provider, { store, children: React.createElement('div', null,
        React.createElement(ArtifactAttachmentPreview, { artifactId: 'art_shot', artifact, session, debugId: 'att' }),
        React.createElement(ArtifactImagePreview, { artifactId: 'art_shot', artifact, session, debugId: 'thumb', alt: sealedName }),
      ) }));
    });
    await settle(() => /Encrypted — unlock vault to view/.test(doc.body.textContent || ''));
    assert.equal(doc.querySelector('img'), null, 'no image is built from ciphertext');
    assert.match(doc.body.textContent || '', /Encrypted — unlock vault to view/);
    assertNoCiphertext();

    await act(async () => { await unlockVault(store, KEY_HEX); });
    await settle(() => doc.querySelectorAll('img').length === 2 && doc.querySelector('[data-debug-id="att-image"]')?.getAttribute('alt') === 'checkout-flow.png');
    const image = doc.querySelector('[data-debug-id="att-image"]') as HTMLImageElement;
    assert.ok(image, doc.body.innerHTML);
    assert.equal(image.getAttribute('alt'), 'checkout-flow.png');
    assert.deepEqual(await bytesOf(madeFrom.get(image.getAttribute('src')!)!), [...PNG]);
    assert.equal(doc.querySelector('[data-debug-id="thumb"]')?.getAttribute('alt'), 'checkout-flow.png');
    assertNoCiphertext();
  } finally {
    await act(async () => root.unmount());
    await lockVaultFully(store);
    globalThis.fetch = previousFetch;
    URL.createObjectURL = previousCreate;
    URL.revokeObjectURL = previousRevoke;
    for (const k of Object.keys(saved)) (globalThis as any)[k] = saved[k];
    dom.window.close();
  }
});
