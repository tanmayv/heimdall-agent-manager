# Vault Keyring Scope Collision — Problem Statement

## Status

Problem statement only. Remediation design and implementation are deferred to a future iteration.

## Problem

Heimdall Bridge vault keys stored in the Linux user keyring use the fixed description
`heimdall:vault_key`. The key is therefore scoped to the operating-system user rather than to a
specific Hub, Hub user, enrollment, or Bridge installation.

When multiple Bridges run as the same operating-system user, including a production Bridge and an
isolated local-development Bridge, every Bridge can resolve the same keyring entry. A Bridge may
therefore report its vault as `unlocked` and encrypt outbound data even though the Hub to which it is
currently connected has no vault configured and its UI has no matching decryption key.

## Observed Failure

During local Hub and Bridge testing:

- The local Bridge reported `vault_status: unlocked`.
- The clean local Hub returned `user vault is not configured`.
- The Linux user keyring contained an entry named `heimdall:vault_key` created outside the isolated
  local test stack.
- Agent conversation titles and messages were persisted as `vault:v1:...` ciphertext.
- The local UI could not decrypt those records and displayed encrypted content.

The Bridge and Hub were individually reporting their actual local state, but those states referred
to unrelated vault contexts. The shared keyring namespace made the combined system appear valid
while encryption and decryption keys were not paired.

## Impact

- A Bridge can silently use key material belonging to another Hub or enrollment context.
- Hub and Bridge vault-status indicators can disagree without clearly identifying the mismatch.
- Messages, titles, terminal content, filesystem content, or other protected fields can be encrypted
  with a key unavailable to the connected Hub UI.
- Records written under the unintended key remain unreadable unless the exact original key is made
  available to the UI.
- Local testing can interfere with or depend on production key state when both Bridges run as the
  same operating-system user.
- Locking, replacing, or purging the shared keyring entry for one Bridge may affect other Bridge
  processes using that operating-system account.

## Required Future Investigation

A future iteration must define the intended isolation boundary for Bridge vault keys and ensure that
key lookup, storage, status reporting, locking, enrollment, restart, and cleanup all use the same
unambiguous vault identity. That work is intentionally outside the scope of this document.
