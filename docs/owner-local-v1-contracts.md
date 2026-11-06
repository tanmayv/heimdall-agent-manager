# Owner-local V1 contracts

The original V1 is the minimal **device-only** create/task/comment/read protocol.
The additive single-device fleet/claim/heartbeat schemas and Bridge-attested
capabilities are documented in [owner-local-leases.md](owner-local-leases.md).
[Requirements, submit and independent review](owner-local-lifecycle.md) add strict lifecycle\ninput/attestation domains and device configuration/verdict methods. Remote execution\nand migration remain outside these contracts.
Legacy Hub writer and transport routes are unchanged.

## Wire and signing

`src/contracts/fixtures/owner-local-schema.json` is the ordered field inventory.
Run `python3 scripts/generate-owner-local-contracts.py` to regenerate the Odin
wire structs/schema and TypeScript interfaces/schema. All fields are strings.
Versions and counters use canonical nonnegative decimal strings up to signed
SQLite i64, including values beyond JavaScript's safe integer range.
IDs are at most 160 ASCII characters from `[a-zA-Z0-9_.:-]`.
Unicode content is sealed as vault ciphertext, not placed in IDs.

Parse **original** request bytes with `owner_parse(raw, kind)` / `ownerParse`.
Duplicate decoded keys, unknown/missing members, wrong types, malformed grammar,
non-ASCII envelope values, unsafe counters, and documents over 256 KiB reject.
Protected fields accept structurally canonical vault v2 envelopes (64 KiB each).
Parsing does not prove ciphertext authentication: the owner must decrypt and
authenticate with the appropriate vault key before committing content.
Deletion metadata has no title bodies; retired receipts have no result bodies.

`owner_canonical(kind, object)` / `ownerCanonical` returns the ASCII domain
`heimdall-owner-local/<kind>/v1` plus newline, followed by schema-ordered
`<ASCII-byte-length>:<value>,` netstrings. Detached signatures are omitted;
all other fields, including key IDs, bind. `owner_digest` / `ownerDigest`
returns lowercase SHA-256 of these bytes. Signatures use existing vault
ECDSA P-256/SHA-256, lowercase 128-hex raw `r||s`. Genesis carries signatures
from both the creating device and recipient Bridge. Their roles/key IDs bind
account, chain, creation operation, owner Bridge/key and schema version.

Command `payload_digest` is SHA-256 of the exact separately supplied UTF-8
payload JSON bytes, not a reserialized tree. `owner_payload_kind(method)` /
`ownerPayloadKind` selects its strict schema:

| Method | Payload kind |
| --- | --- |
| `chain.create` | `chain_create_payload`: genesis digest, protected title/description |
| `task.create` | `task_create_payload`: protected title/body |
| `task.comment` | `comment_payload`: protected body |
| `chain.read`, `task.read` | `read_payload`: cursor and limit, at most 100 |
| `receipt.read` | `receipt_payload`: target operation ID |

Task methods require a task ID; chain/receipt methods require the empty task ID.
A result receipt is historical data and conveys no mutation authority.

## Owner integration API and required order

Odin helpers: `src/contracts/owner_local.odin`; TS mirror:
`src/ui/api/ownerLocal.ts`. Odin parsed trees/canonical strings use the temporary
allocator; clone anything retained beyond the request.

1. Resolve the signing key from **current verified account directory** state and
   read grant from **current owner-local storage**. Populate `Owner_Verified_Key`
   / `OwnerVerifiedKey` and `Owner_Read_Grant` / `OwnerReadGrant` there.
   Neither record is a request assertion. Existing vault directory/pairing code
   verifies enrollment proofs; these helpers consume its result. Content keys,
   Hub relay credentials and claimed principals cannot create trusted records.
   Grants authorize one exact method; empty grant task ID means that chain.
2. Parse the command and call `owner_authenticate_command` /
   `ownerAuthenticateCommand` with exact payload, key, current grant and owner
   clock. It binds account/owner/chain/principal/key/method/task, verifies the
   device signature and payload digest/schema, and requires current read access.
   Bridge/agent/content-key command authority rejects in V1.
3. Open the local transaction and recheck authentication/read authorization.
   Lookup `(principal_id, operation_id)` and compare method/input digest from
   `owner_digest("command", command)`. A matching historical receipt returns
   read-only with no effects, even after request expiry or removal of mutation
   rights. Revoked/expired read grants deny replay. Changed input conflicts;
   retired tombstones reject. Neither is a receipt miss.
4. Only on receipt miss call `owner_live_admit` / `ownerLiveAdmit` using the
   **same current grant** and current resource revision. It rechecks scope,
   limits request expiry to the next five minutes, requires mutation permission
   for writes, and checks expected revision. Initial reads can use revision
   `"0"`; nonzero pinned read revisions must match. Negative clocks/revisions
   reject. Clock recovery/high-watermark policy remains the runtime's job.
5. Creation additionally calls `owner_verify_genesis` / `ownerVerifyGenesis`
   with enrolled recipient Bridge and creator device, then
   `owner_create_binding` / `ownerCreateBinding` to match command, genesis and
   payload. Insert genesis **once**, atomically with state, receipt and publication
   intent. Validation alone cannot enforce database immutability.
6. Registry publication uses `owner_verify_registry` / `ownerVerifyRegistry`
   against the receiver's pinned genesis digest and enrolled owner key. Storage
   resolves the correct chain first and enforces ordered revision/CAS and deletion
   tombstones. Registry accepts no task status/detail fields. Offline details
   return `owner_unavailable`; no alternate writer or fallback.

The consumer supplies revocation freshness, durable deduplication/tombstones,
write locking, atomicity, decryption, bounded scoped cursors/results and relay
confidentiality. Helpers do not silently provide these runtime guarantees.
`owner_auth_error_code` maps Odin validation errors to shared wire strings.

## Verification

`src/contracts/fixtures/owner-local-v1.json` pins public P-256 keys, detached
signatures, canonical bytes, digests, strict rejections and all six signed method
requests. Both languages consume these vectors. Ciphertext vectors are structural
test tokens and do not claim decryption success. Tests exercise signature/body
tampering, account/owner/task/method scope, enrollment/key roles, revoked/expired
read grants, large counters, creation binding and historical authentication
versus live expiry/revision admission.
