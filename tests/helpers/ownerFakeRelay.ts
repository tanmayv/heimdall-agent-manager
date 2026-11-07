// A fake owner Bridge behind the owner relay for UI tests (R4b): it opens the
// sealed relay envelope, checks the signed command parses, lets the test answer
// per method, and seals a reply bound to the exact command digest (what
// openOwnerReply verifies). `'offline'` answers like the Hub when the owner
// Bridge is not connected.

import { FakeHub, USER, newBrowser } from './vaultDirectoryFixture.ts';
import { installKeyringFromWrap, getKeyringSession } from '../../src/ui/utils/vaultKeyringSession.ts';
import { decryptVaultText, encryptVaultText } from '../../src/ui/utils/vaultContent.ts';
import { ownerDigest, ownerParse } from '../../src/ui/api/ownerLocal.ts';
import type { OwnerSession } from '../../src/ui/api/ownerLocalClient.ts';

export interface OwnerTestEnv { session: OwnerSession; hub: FakeHub; bridgeId: string; bridgeName: string }

/** A real enrolled browser + one enrolled Bridge, with the keyring installed. */
export async function ownerTestSession(bridgeId = 'brg_home', bridgeName = 'Home Bridge'): Promise<OwnerTestEnv> {
  const identity = await newBrowser();
  const hub = new FakeHub();
  await hub.genesis(identity);
  await hub.addBridge(identity, bridgeId, bridgeName);
  await installKeyringFromWrap(identity, hub.wraps.get(identity.deviceId), await hub.chain());
  const s = getKeyringSession()!;
  return { session: { identity: s.identity, chain: s.chain, keyring: s.keyring }, hub, bridgeId, bridgeName };
}

export interface OwnerCall { method: string; command: Record<string, string>; payload: Record<string, string>; genesis: string }
export type OwnerAnswer = 'offline' | { code: string } | Record<string, unknown>;

export function fakeOwner(session: OwnerSession, answer: (call: OwnerCall) => OwnerAnswer | Promise<OwnerAnswer>, calls: OwnerCall[] = []) {
  return async (relay: any): Promise<unknown> => {
    const operation = JSON.parse(await decryptVaultText(relay.envelope, session.keyring));
    const command = ownerParse(operation.command, 'command') as unknown as Record<string, string>;
    const call: OwnerCall = { method: command.method, command, payload: JSON.parse(operation.payload), genesis: operation.genesis };
    calls.push(call);
    const out = await answer(call);
    if (out === 'offline') return { code: 'owner_unavailable' };
    const code = typeof (out as any).code === 'string' && Object.keys(out).length === 1 ? (out as any).code : 'ok';
    const result = {
      request_id: relay.request_id, input_digest: await ownerDigest('command', command as any), code,
      body: code === 'ok' ? JSON.stringify(out) : '', commit_seq: '1', replay: false,
    };
    return { code: 'ok', envelope: await encryptVaultText(JSON.stringify(result), session.keyring) };
  };
}

/** A sealed registry row as the Hub lists it. */
export async function registryRow(session: OwnerSession, o: {
  chainId: string; taskId?: string; bridgeId: string; online: boolean; chainTitle?: string; taskTitle?: string; deleted?: boolean;
}) {
  const registry = {
    protocol_version: '1', account_id: USER, chain_id: o.chainId, owner_bridge_id: o.bridgeId, key_id: 'bridge_key',
    genesis_digest: 'a'.repeat(64), metadata_revision: '1', task_id: o.taskId ?? '',
    chain_title_cipher: await encryptVaultText(o.chainTitle ?? 'Chain', session.keyring),
    chain_description_cipher: await encryptVaultText('', session.keyring),
    task_title_cipher: await encryptVaultText(o.taskTitle ?? '', session.keyring),
    deleted: o.deleted ? '1' : '0', signature: '0'.repeat(128),
  };
  return { chain_id: o.chainId, owner_bridge_id: o.bridgeId, owner_key_id: 'bridge_key', task_id: o.taskId ?? '', registry_json: JSON.stringify(registry), online: o.online };
}
