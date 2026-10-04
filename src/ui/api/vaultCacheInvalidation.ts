// Vault cache invalidation middleware (REQ-CACHE-1)
//
// Every vault-bearing endpoint decrypts inside its `queryFn`, gated on
// `state.vault.isUnlocked && getActiveVaultKey()` -- see `sidebar.ts:238-242`,
// `projects.ts:36-42`, `memory.ts:248-250` and nine more. That gate is evaluated
// exactly once, at FETCH time. A list fetched while the vault was locked is
// therefore cached in its ARMORED form and nothing ever revisits it: unlocking
// flips `isUnlocked`, but the cache entry is already settled, so the armored rows
// stay on screen until some unrelated action happens to refetch them.
//
// WHY A MIDDLEWARE AND NOT EDITS AT THE DISPATCH SITES
// There are eight `setVaultUnlocked` dispatch sites (`vaultSlice.ts:118` session
// restore, `BridgeSettingsPanel.tsx:306`, `VaultOnboardingModal.tsx:259/:298/:339`,
// `VaultPanel.tsx:229/:269/:312`) plus three paths that clear the flag
// (`lockVault`, `setVaultConfigured(false)`, and `setVaultUnlocked(undefined)`).
// Per-site invalidation is what produced this bug class in the first place -- it is
// correct only until the next site is added. This middleware keys on the STATE
// TRANSITION instead, so it covers all eleven paths and every future one for free,
// including transitions that originate outside the vault slice entirely.
//
// WHY `resetApiState` AND NOT `invalidateTags`
// The surgical option would be an `invalidateTags` over the vault-bearing tag
// types. Ten endpoint files decrypt at fetch time (`agentsLive`, `artifacts`,
// `chats`, `issues`, `memory`, `projectFs`, `projects`, `sidebar`, `taskChains`,
// `tasks`) and between them declare roughly half of the ~57 tag types.
// (`bridges.ts` and `shells.ts` also touch the vault but only to ENCRYPT an
// outbound payload -- an unseal envelope and a shell `enc_spec` -- so neither
// caches a decryptable result and neither belongs on this list.)
// That list can only be derived by hand, and a future endpoint that
// decrypts under a tag nobody remembered to add escapes the invalidation
// SILENTLY -- the identical failure mode this task exists to end. `resetApiState`
// is complete by construction. Its cost is a one-time refetch of the non-vault
// queries on a user action that happens about once per session.
//
// WHY LOCK RESETS TOO (criterion 3)
// On lock, decrypted PLAINTEXT is sitting in the cache. `invalidateTags` would
// leave it resident in unsubscribed entries for `keepUnusedDataFor: 30` seconds
// (`heimdallApi.ts:108`); a reset drops it in the same tick. The idiom precedent
// is `clearPriorUserClientState` at `AppShell.tsx:904`.
//
// Live shell and agent panes are NOT disturbed by either reset: both stream over a
// WebSocket owned by `useShellStream`/`useAgentStream` (`useShellStream.ts:196`),
// not over an RTK Query cache entry.

import { heimdallApi } from './heimdallApi';

function readIsUnlocked(state: unknown): boolean {
  return Boolean((state as { vault?: { isUnlocked?: boolean } } | undefined)?.vault?.isUnlocked);
}

/**
 * Redux middleware that resets the RTK Query cache whenever the vault crosses the
 * locked/unlocked boundary. It compares `state.vault.isUnlocked` before and after
 * the action is reduced, so it reacts to a genuine transition rather than to any
 * particular action type -- re-dispatching `setVaultUnlocked` while already
 * unlocked is a no-op here, and so is a lock while already locked.
 *
 * `resetApiState` does not touch `state.vault`, so this cannot recurse.
 */
export const vaultCacheInvalidationMiddleware =
  (store: { getState: () => unknown; dispatch: (action: unknown) => unknown }) =>
  (next: (action: unknown) => unknown) =>
  (action: unknown) => {
    const before = readIsUnlocked(store.getState());
    const result = next(action);
    const after = readIsUnlocked(store.getState());

    if (before !== after) {
      // Both directions reset: unlock so the armored cache is re-fetched and
      // decrypted, lock so decrypted plaintext does not outlive the key.
      store.dispatch(heimdallApi.util.resetApiState());
    }

    return result;
  };

export default vaultCacheInvalidationMiddleware;
