> **Removed (2026-11-10).** Per-chain device grants, `grant.*`, the recovery
> policy and paired-root recovery no longer exist. Owner chains use
> account-level trust: every paired, unrevoked device of the account reads and
> changes every owner chain. The tables stay for migration history. This
> document is kept as history only.

# Owner-local device grants and recovery

The immutable owner Bridge stores and enforces these grants. Vault content keys
and account login alone do not authorize chain detail, search, mutations or
historical replies. Grants apply to exactly one account, owner, chain and
currently enrolled browser signing key. They authorize chain reads, with optional
chain mutations; they do not authorize grant administration or agent leases.

## Administration

Open **Owner-local tasks**, select the chain and its immutable owner, and use
**Read grants and policy** to obtain the current chain revision. The creator must
still be enrolled and have a live read/write grant to change access. Select an
enrolled browser, set the expiry as Unix milliseconds, choose **Allow chain
mutations** if needed, and click **Save device grant**. Saving creates or replaces
that browser's grant and increments its revision. **Revoke device grant** revokes
it immediately on this owner. The recipient-ID field also accepts a removed
device so a directory-revoked browser's local grant can be revoked.

These are signed commands, with exact payload digests, chain-revision compare and
swap, durable deduplication and immutable signed audit records. Grant changes,
audit evidence, receipts and the chain revision commit atomically. Read grants is
paged (at most 100 per request); its cursor is bound to the reader and chain
revision. A concurrent change requires restarting pagination.

| Method | Signed payload | Authority |
| --- | --- | --- |
| `grant.set` | `principal_id,key_id,expires_ms,can_read,can_mutate` | Current creator, or paired root with a live grant and enabled policy |
| `grant.revoke` | `principal_id,key_id` | Same as set; recipient need not remain enrolled |
| `grant.read` | `cursor,limit` | Current creator with live read grant, or current paired root under enabled policy |
| `grant.policy` | `policy_revision,recovery_enabled` | Current creator, or paired root with a live write grant and enabled policy |
| `grant.recover` | Same as set | Current paired-root signature plus enabled owner-local policy, independently of creator |

All numeric and boolean wire values are canonical decimal strings; flags are
`"0"` or `"1"`. Read is required for a live grant (`can_read="1"`); use revoke
to remove it. Neither delegated read nor delegated write permits administration.
Current target enrollment, account and key are verified from the same signed,
paired-root directory used for the command signer. The owner cannot be changed.

Each mutation uses the current chain revision. Task revisions are separate.
Successful replies include the resulting chain revision; read grants returns the
current revision and the policy revision. A policy change must use exactly the
next policy revision (starting at 1). Merely checking the UI checkbox does not
enable recovery: **Save recovery policy** must successfully commit it.

## Explicit paired-root recovery

Recovery is disabled by default, including on upgraded chains. While the
creator remains available, it can opt in by signing `grant.policy` with
`recovery_enabled="1"`. This is a deliberate trust decision: the currently
enrolled browser whose signing key matches the Bridge's durable paired root can
then issue bounded access even after the creator is lost, directory-revoked,
locally revoked or expired. The root receives no implicit content-read grant.

After creator loss/revocation, unlock the paired-root browser, select the owner
and chain, click **Read grants and policy**, select the replacement enrolled
browser, set expiry/rights, and click **Recover access as paired root**. Recovery
verifies the actual root command signature as well as current enrollment and
the enabled local policy. It does not manufacture a creator signature, rewrite
genesis, change the immutable owner, or trust an asserted Hub identity. The root
can recover a bounded grant for itself, then explicitly disable recovery using
the next policy revision. Disabling the policy also prevents replay of old
recovery commands. Revoking a root's ordinary content grant does not disable its
separate opted-in recovery authority; disable the policy for that purpose.

An ordinary replacement/delegated browser cannot recover or administer access.
If the paired root is unavailable or no recovery policy was enabled before all
administrators became unavailable, this implementation safely refuses in-place
recovery. There is **no supported bypass**, Hub override, automatic authority
from a vault key, or direct-SQL recovery flow. Preserve the owner files and
backups. Recover the original authorized browser/root signing identity through
its existing protected backup process, if available; otherwise this chain
remains inaccessible through the API. Authenticated owner migration/restore is a
separate integration gate, not a fallback implemented by this feature. Do not
delete the local database or reassign its owner to try to recover access.

## Expiry, offline operation and irreversible copies

New creator and delegated content grants last **at most 30 days**. The creator
must renew its own grant before expiry, or have explicitly opted into root
recovery. The UI defaults delegated grants to one day; it never silently renews.
On V7 upgrade, previously unbounded grants are clamped to at most 30 days after
the last durable owner clock observation, with a grant-revision increment. An
old owner that has been disconnected longer may therefore already require its
enabled root recovery policy; the upgrade never silently opts in a chain.

The owner checks grant expiry and revocation **before historical receipt
lookup**, detail reads and search snippets. Request expiry is different:
an unchanged successful command may return its historical receipt after its
five-minute request lifetime, provided current read authority still exists.
Removing mutation rights does not remove that read authority. Revoking/expiring
the content grant or directory signer does. Search never falls back to Hub
content. A stopped/offline owner returns `owner_unavailable` and no detail
envelope, although protected account-owned registry titles remain discoverable.

Local grant revocations apply at commit, including while disconnected from the
Hub. Directory revocation takes effect when its authenticated newer directory
is observed; the owner pins directory sequence/hash and rejects rollback.
A disconnected owner cannot know about an unseen remote revocation. Reusing an
older still-pinned signed directory cannot extend the 30-day content grant.
The expiry check uses the owner wall clock, with the durable clock high-water
mark as a lower bound for read authorization. A trusted host clock remains
required; this feature adds no independent secure clock or online freshness
oracle. Existing backward-clock mutation recovery remains fail closed.

Access removal cannot erase plaintext or ciphertext already delivered to a
browser, copied elsewhere, printed or retained in an old content keyring.
Revocation prevents future authorized owner responses, not possession of prior
decrypted data. Owner canonical files and the derived search index remain
decrypted in the private owner directory; use encrypted storage and protect
backups. Browser caching and artifact-content indexing remain deferred.

## CLI flow and synthetic verification

The UI signs all grant operations with the browser identity. **Export signed
request for CLI** exports only the sealed relay, not a private signing/content
key. With an authorized running local instance transport:

```bash
./bin/ham-ctl task-chain owner-local relay \
  --request-file /path/to/owner-local-request.json > owner-local-response.json
```

Use **Open CLI response** in that browser panel to verify/decrypt the reply.
This is the existing usable CLI relay flow, not a native CLI key/login feature.

Focused checks:

```bash
nix develop --command odin test src/lib/owner_local -collection:odin_test=src \
  -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/grants-store-$$
nix develop --command odin test src/contracts -collection:odin_test=src \
  -define:ODIN_TEST_FANCY=false -out:$HOME/.cache/heimdall-tests/grants-contracts-$$
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts \
  --test tests/ui_owner_grants_test.ts tests/ui_owner_local_contract_test.ts
```

The disposable enrollment demo in [owner-local-v1-demo.md](owner-local-v1-demo.md)
accepts `HEIMDALL_E2E_OWNER_GRANTS=1` alongside
`HEIMDALL_E2E_OWNER_LOCAL=1`. It uses real signed browser enrollment, the actual
Hub/Bridge/CLI, the rendered production grant controls, creator directory
revocation with key rotation, paired-root recovery, local revoke/replay/search
denials, expiry, restart and offline-owner denial. Grant changes never edit SQL
fixtures. Existing `OWNER_LEASE`, lifecycle/Git, `OWNER_CONTROLS` and
`OWNER_REGISTRY` demos can be enabled together; all processes, identities and
databases are disposable. No production credentials or services are used.
