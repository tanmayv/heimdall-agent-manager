import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  approvedBridgeIsOnline,
  BRIDGE_HOME_REDIRECT_DELAY_MS,
  nextAvailableBridgeLabel,
} from '../src/ui/components/enrollment/bridgeEnrollmentCompletion.ts';
import {
  getActiveBridgeVaultKeyMaterial,
  setActiveBridgeVaultKeyMaterial,
  setActiveVaultKey,
} from '../src/ui/utils/vaultCrypto.ts';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

test('completion requires the exact approved bridge to be online', () => {
  const bridges = [
    { bridge_id: 'other', status: 'online' },
    { bridge_id: 'approved', status: 'offline' },
  ];
  assert.equal(approvedBridgeIsOnline(bridges, 'approved'), false);
  assert.equal(approvedBridgeIsOnline([{ bridge_id: 'approved', status: 'online' }], 'approved'), true);
  assert.equal(approvedBridgeIsOnline([{ id: 'approved', runtime_status: 'connected' }], 'approved'), true);
  assert.equal(approvedBridgeIsOnline(null, 'approved'), false);
  assert.equal(approvedBridgeIsOnline(bridges, ''), false);
});

test('new bridge names start at hostname and use the first free numeric suffix', () => {
  assert.equal(nextAvailableBridgeLabel('dawnstar', []), 'dawnstar');
  assert.equal(nextAvailableBridgeLabel('dawnstar', [{ label: 'dawnstar' }]), 'dawnstar-2');
  assert.equal(
    nextAvailableBridgeLabel('dawnstar', [
      { label: 'DAWNSTAR' },
      { label: 'dawnstar-2' },
      { label: 'dawnstar-4' },
    ]),
    'dawnstar-3',
  );
  assert.equal(nextAvailableBridgeLabel('', []), 'bridge');
});

test('bridge key material is session-only and invalidated whenever the active key changes', () => {
  const raw = 'ab'.repeat(32);
  setActiveVaultKey({} as CryptoKey);
  setActiveBridgeVaultKeyMaterial(raw);
  assert.equal(getActiveBridgeVaultKeyMaterial(), raw);

  setActiveVaultKey({} as CryptoKey);
  assert.equal(getActiveBridgeVaultKeyMaterial(), null);

  setActiveBridgeVaultKeyMaterial(raw);
  setActiveVaultKey(null);
  assert.equal(getActiveBridgeVaultKeyMaterial(), null);
});

test('successful enrollment redirects home after three seconds', () => {
  assert.equal(BRIDGE_HOME_REDIRECT_DELAY_MS, 3000);
  const source = fs.readFileSync(
    path.join(repoRoot, 'src/ui/components/enrollment/BridgeEnrollmentApprovalPage.tsx'),
    'utf8',
  );

  assert.match(source, /className="animate-spin"/);
  assert.match(source, /cookieJsonFetch\('\/bridges'\)/);
  assert.match(source, /approvedBridgeIsOnline\(list, targetBridgeId\)/);
  assert.match(source, /bridgeConnected\s*&&/);
  assert.match(source, /delivery\.phase === 'delivered'/);
  assert.match(source, /delivery\.phase === 'not-needed'/);
  assert.match(source, /window\.setTimeout\([\s\S]*navigateEnrollmentHome[\s\S]*BRIDGE_HOME_REDIRECT_DELAY_MS/);
});

test('approval is a standalone minimal consent page', () => {
  const page = fs.readFileSync(
    path.join(repoRoot, 'src/ui/components/enrollment/BridgeEnrollmentApprovalPage.tsx'),
    'utf8',
  );
  const shell = fs.readFileSync(
    path.join(repoRoot, 'src/ui/components/shell/AppShell.tsx'),
    'utf8',
  );

  assert.match(shell, /if \(path === '\/enroll\/approve'\)[\s\S]*enrollment-standalone-page/);
  assert.match(page, /enrollment-device-hostname/);
  assert.match(page, /enrollment-device-os/);
  assert.match(page, /enrollment-new-bridge-name-input/);
  assert.match(page, /new_bridge_label:/);
  assert.doesNotMatch(page, /Verified by Heimdall/);
  assert.doesNotMatch(page, /Claimed by the machine/);
  assert.doesNotMatch(page, /Request came from/);
  assert.doesNotMatch(page, /Fingerprint method/);
  assert.doesNotMatch(page, /Public key \(from link\)/);
  assert.doesNotMatch(page, /Callback port/);
});
