import { decryptVaultText, encryptVaultText, isWholeVaultArmored, type VaultKeyring } from './vaultCrypto';
import { writeClientStorageChecked } from './clientPersistence';

type Intent = { body: string; artifactIds: string[]; createdAt: number };
const locks = new Map<string, Promise<unknown>>();
const intentPrefix = (owner: string, conversationId: string, vault: VaultKeyring) =>
  `heimdall:chat-write:${encodeURIComponent(owner)}:${vault.vaultId}:${encodeURIComponent(conversationId)}:`;

async function getUnconfirmed(prefix: string, vault: VaultKeyring) {
  // The key is an opaque id. The body and attachment IDs are vault ciphertext,
  // including when the tab or browser closes before an acknowledgement.
  const storage = window.localStorage;
  const keys = Object.keys(storage).filter(key => key.startsWith(prefix));
  const entries: { storageKey: string; key: string; intent: Intent }[] = [];
  for (const storageKey of keys) {
    const envelope = storage.getItem(storageKey);
    if (!envelope || !isWholeVaultArmored(envelope)) continue;
    let intent: Intent;
    try { intent = JSON.parse(await decryptVaultText(envelope, vault)); }
    catch { continue; }
    if (!intent || !Number.isFinite(intent.createdAt) || typeof intent.body !== 'string' || !isWholeVaultArmored(intent.body) ||
      !Array.isArray(intent.artifactIds) || !intent.artifactIds.every(id => typeof id === 'string')) continue;
    entries.push({ storageKey, key: storageKey.slice(prefix.length), intent });
  }
  return entries;
}

function confirmed(storageKey: string) {
  // A failed local cleanup is safe: a repeat still uses the acknowledged id.
  try { writeClientStorageChecked(storageKey, null); } catch {}
}

export async function restoreChatWriteIntent(owner: string, conversationId: string, vault: VaultKeyring) {
  const entries = await getUnconfirmed(intentPrefix(owner, conversationId, vault), vault);
  const latest = entries.sort((a, b) => b.intent.createdAt - a.intent.createdAt)[0];
  if (!latest) return null;
  return { ...latest.intent, key: latest.key, confirm: () => confirmed(latest.storageKey) };
}

export async function prepareChatWriteIntent(
  owner: string, conversationId: string, body: string, artifactIds: string[], vault: VaultKeyring,
) {
  const prefix = intentPrefix(owner, conversationId, vault);
  const previous = locks.get(prefix) ?? Promise.resolve();
  const running = previous.catch(() => undefined).then(async () => {
    const wantedArtifacts = JSON.stringify(artifactIds);
    for (const entry of await getUnconfirmed(prefix, vault)) {
      if (JSON.stringify(entry.intent.artifactIds) === wantedArtifacts &&
          await decryptVaultText(entry.intent.body, vault) === body) return entry;
    }
    const key = `web-${crypto.randomUUID()}`;
    const intent = { body: await encryptVaultText(body, vault), artifactIds, createdAt: Date.now() };
    const storageKey = prefix + key;
    const sealed = await encryptVaultText(JSON.stringify(intent), vault);
    writeClientStorageChecked(storageKey, sealed);
    return { storageKey, key, intent };
  });
  locks.set(prefix, running);
  try {
    const entry = await running;
    return {
      body: entry.intent.body,
      key: entry.key,
      confirm: () => confirmed(entry.storageKey),
    };
  } finally {
    if (locks.get(prefix) === running) locks.delete(prefix);
  }
}
