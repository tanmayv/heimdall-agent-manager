# Owner-local durable search

The existing encrypted chain search now includes chains owned by each enrolled
Bridge, alongside unmigrated legacy chains. The owner receives a device-signed
`chain.search` through the existing owner relay. The browser queries immutable
owners independently; a different Bridge's legacy index is never a fallback for
an unavailable owner's detail. Owner IDs are excluded from legacy results even
when the owner denies access or is offline. Results remain transient and a
changed vault session discards late replies.

The home/sidebar/selector search still presents one row per matching chain.
Selecting an owner-local chain opens its owner panel; **Search chain** there
returns matching objects with task ID, kind, object revision and indexed commit
sequence. Owner metadata has no project or status. A project filter keeps an
owner chain only when the Hub lists its frozen copy in that project with
`authority:{kind:"owner"}` (a migrated chain; `loadProjectOwnerChainIds` in
`src/ui/utils/taskChainSearch.ts`); native owner chains never match a project.
An archived/cancelled status filter excludes owner chains, other status filters
keep them marked unchecked. Chain lists drop every Hub row marked owner-held,
so a frozen copy stays hidden even after the owner registry tombstones the
chain (`mergeOwnerChains`, `homeChainsWithOwners`). At most 100 owner chains, four concurrent requests, 50 objects per chain,
256 query bytes/16 literal terms, 64 KiB per owner result, five seconds of browser
request time and two million SQLite VM instructions per query are allowed.
Oversized scopes fail explicitly; interrupted owner requests mark the combined
result incomplete/stale. Order is deterministic, without global BM25 statistics.

## Indexed sources

| Source | Behavior |
| --- | --- |
| Chain title/description and task title/body | Current canonical local row |
| Task comments | All retained local comments |
| Goals/acceptance | Current immutable requirements revision's brief JSON |
| Submission output | Every retained local submission summary, keyed by task ID and attempt |
| Linked messages/handoff | No owner-local producer exists yet; deferred with controls/linked-content work |
| Artifacts, extractors, binary content, terminal output | Not indexed |

No filesystem crawl or imported message grant is inferred. Legacy coverage keeps
its existing encrypted feed and in-memory chain-title/description index.

## Writes, access and storage

`search_docs` and external-content FTS5 live in the owner runtime SQLite database.
Source-table triggers upsert/delete documents and postings in the canonical
transaction, including requirements/submission writers. Failed statements,
deferred-constraint COMMIT failure and disk-full roll back content and postings.
V5 migration adds the index; V6 atomically upgrades its output identities and backfills every retained submission, including on existing V5 databases. Opening a database rebuilds
documents from canonical rows, rebuilds FTS and checks external-content integrity.
A rebuild failure disables search; it cannot yield stale successful results.

Every search revalidates the enrolled device's signature, owner/account,
directory pin and current local read grant before querying. An explicitly
materialized allowed scope precedes MATCH/snippet extraction. A read-only grant
can search; revoked/expired grants cannot. Vault keys decrypt transport and
query text but confer no authority. Lock/keyring generation is checked before
sealing and again after publication I/O, immediately before dispatch. The shared
SQLite authority connection remains open; locked callers cannot query through
it. Browser request abortion/session checks discard late results. Already
delivered plaintext cannot be remotely recalled.

New signed `chain.edit`, `task.edit` and `task.delete` provide content maintenance
with exact revisions, durable receipts and signed title/delete publication.
Historical output hits carry an explicit attempt, and links open
/chains/:chain/tasks/:task/submissions/:attempt. The owner panel labels the view
as historical output and sends signed submission.read for that exact attempt;
it never substitutes the current runtime summary. Reads recheck current grants,
are read-only and return bounded summary pages (8192 bytes, UTF-8 boundaries).
An absent attempt or revoked/cross-scope read fails closed. Requirements and
configuration revision, author and head identify the immutable submitted record.

Task edit/delete rejects tasks with any lease history or lifecycle configuration;
these commands cannot bypass review/merge controls. Delete removes the unstarted
task and comments plus their documents/postings in one transaction, and retains
an immutable ID/sequence tombstone. The ID cannot be recreated. Historical
read-authorized delete replay returns the original receipt without another write.

The Bridge uses its account-specific private directory. POSIX setup enforces
directory `0700` and DB/writer/WAL/SHM `0600`. Task/search text is decrypted on
disk: use an encrypted OS volume. This code does not detect or provide filesystem
encryption. The owner panel states this policy. Vault lock denies requests and
clears session results; it does not erase existing files or stop already admitted
transactions. OS administrators can inspect unlocked local storage.
Windows inherits profile ACLs; equivalent ACL and platform behavior have not
been validated by this Linux gate.

Deleting postings is logical deletion, not forensic erasure of WAL pages,
old segments, SSD blocks, snapshots or backups. No backup/restore, purge, volume
verification or secure-erasure product flow is introduced here. Restore fencing,
backup deletion acknowledgements and recovery activation remain M4. Never copy
a database into another owner or activate a stale backup as a live writer.

## Verification

The existing commands in [owner-local-lifecycle.md](owner-local-lifecycle.md)
build/run the disposable real Hub/Bridge/CLI/PTY integration demo. Its
`owner_local_flow.ts` now tests signed CLI/UI-client search create/comment/edit/
delete, Unicode, restart/rebuild, chain/account isolation, mixed legacy/local
results without duplicates, and late-result rejection after session lock. A two-submission rework cycle
then checks retained output across owner restart and renders the production
owner panel from each exact search link against the real relay.
The same run retains exact-child claim/heartbeat, requirements/ACK, submit
replay, independent review and real Git merge/conflict checks. It uses production
browser modules rather than browser automation or native provider-interrupt tests.
Hub SQLite/WAL and Hub logs are scanned for local prose/query markers.

Focused suites:

```bash
nix develop --command odin test src/lib/owner_local \
  -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/owner-search-unique
nix develop --command odin test src/contracts \
  -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/contracts-search-unique
nix develop --command node --import ./tests/helpers/vaultEndpointHarness.ts \
  --test tests/ui_owner_local_contract_test.ts tests/ui_owner_submission_history_test.ts tests/ui_home_chain_search_test.ts
nix develop --command npm run typecheck
```

Storage tests include genuine V4/V5 collision/rollback/backfill, retained
attempt-1/attempt-2 output before and after rebuild/restart, exact-attempt reads
and revocation/cross-scope denial, Unicode/literal
queries, source update/delete/replay, tombstone resurrection rejection, readonly/
revoked scope, missing key, failed repair, failed COMMIT/disk-full and current
requirements/submission indexing. Workflow/source episodes and R2C regressions
remain explicit successor work; this search slice does not claim them.

V7 adds immutable handoff/control prose (summary, next steps and waiting reason)
to scoped search. Changes and documents commit with the command receipt and
rebuild from canonical handoff rows after restart. See
[owner-local-controls.md](owner-local-controls.md).
