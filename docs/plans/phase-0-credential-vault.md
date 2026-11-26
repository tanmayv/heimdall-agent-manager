# Phase 0 credential vault and browser conventions

**Review target.** An owner saves a credential in Settings, copies its opaque reference into a task, and an agent on an approved, unlocked bridge can use that reference as input to a trusted Bash command. An agent can also reuse a browser login established on that bridge. The browser profile and credential store have independent lifetimes.

## REQ-VLT-0 · Owner workflow and trust boundary

Add a Vault panel to Settings, alongside the existing Devices panel. Keep device enrollment and recovery in Devices. Wire direct navigation and reopening through `src/ui/components/settings/SettingsModal.tsx`, `src/ui/utils/settingsRouting.ts` and `src/ui/components/shell/AppShell.tsx` (`resolveSettingsTab`, `DeviceVaultGate`). Show a name and a masked credential input. Generate a cryptographically random 128-bit ID before sealing. Allow duplicate names. Copy reference copies only the ID. Edit loads one record on demand. Cancel, lock, logout, reset and unmount clear component state. Keep plaintext out of Redux, query keys, persistent caches, analytics and error reports. Guard async completions with the session generation to avoid redisplaying data after lock or account change.

The existing design in `docs/plans/passwordless-vault.md` uses an owner directory and epoch keys. `src/hub/repository/sqlite/vault_directory_repo_sqlite.odin` stores the directory behind `src/hub/repository/iface/vault_directory_repo.odin`. `src/ui/utils/vaultKeyringSession.ts` installs a verified device wrap with `installKeyringFromWrap` and drops the session with `clearKeyringSession`. `src/ui/utils/vaultKeyring.ts` imports owner-bound bytes and selects keys with `currentKey` and `keyFor`. Use the current epoch for every new write and the specified historical epoch for reads. Refuse writes under stale vault ID/epoch, checking current directory state in the mutation transaction. Namespace queries by current vault ID so reset immediately isolates old records; retire obsolete rows using the reset queue specified below. Rotation retains access to older ciphertext on still-approved devices. Revocation cannot erase previously learned values or invalidate third-party sessions.

Seal name and secret payload separately to list names without moving values. Use the authenticated-context pattern of `sealFsWriteContent` and `openFsWriteContent` in `src/ui/utils/vaultCrypto.ts`. Define an interoperable length-prefixed UTF-8 context containing protocol version, owner, vault ID, epoch, ID, record revision and field tag. Use fresh random nonces for both fields and re-seal both on every edit. Secret payload contains the UTF-8 value. Verify context on opening. Generic text decryption must fail. Lock and unknown epoch fail closed. Publish deterministic TS/Odin vectors using test-only fixed nonces. Hub validates full envelope syntax, encoded bounds, declared epoch and vault ID. Only key holders can verify authenticated plaintext. Hub observes IDs, sizes, revisions and access patterns.

### Store and API

Add an additive migration under `src/hub/repository/sqlite/migrations/` following `src/hub/repository/sqlite/migrations.odin`. Use two rowid tables. `credential_secrets(owner_id,vault_id,id,revision,name_ct)` has a unique composite index on `(owner_id,vault_id,id)`. `credential_secret_payloads(secret_rowid INTEGER PRIMARY KEY REFERENCES credential_secrets(secret_rowid) ON DELETE CASCADE,payload_ct)` stores the large field separately. Declare `secret_rowid INTEGER PRIMARY KEY` explicitly in the parent. Enable and verify foreign keys. Join by integer key only for detail/use. Insert or replace both rows within one transaction, rolling back both if either write fails. Validate canonical lower-case hex IDs, positive integral revisions, overflow, strict request fields and total body size before decoding. Cap clear name at 256 UTF-8 bytes, value at 16 KiB. Bound armored fields at 1 KiB and 32 KiB respectively and body at 40 KiB. Serialize the inner payload with a bounded binary length-prefix format so JSON escaping cannot inflate it past the envelope limit.

| Operation | Database and wire contract |
|---|---|
| List | Select ID, revision and name ciphertext only. Equality on owner and vault, ordered by ID. For subsequent pages add `id > ?`. Bind limit 1–50 (default 25) plus one to determine continuation. Cursor is last returned ID. Live keyset traversal permits concurrent inserts behind the cursor to appear on refresh. |
| Read | Equality on all three primary-key columns. Single detail record. A bridge-only read returns only revision and sealed payload. |
| Create | Insert at revision 1. Unique conflict returns 409. After ambiguous transport failure, read the same ID and compare exact submitted ciphertext before declaring success. |
| Edit/delete | Single conditional UPDATE or DELETE with full primary key and expected revision. Edit increments exactly once. On zero affected, owner-local point lookup in the same transaction distinguishes stale (409) and missing (404). A foreign ID gives the same missing result. Refetch on conflict and let the owner reapply. Delete retry treats absence as achieved. |

Never accept owner from body, cursor or query. For UI routes use authenticated user and approved device signature, covering method, full target including cursor, and exact body, with replay protection. Follow `require_vault_user`, `signed_request` in `src/hub/transport/http/vault_directory_handlers.odin` and `verify_request(.Approved)` in `src/hub/service/vault_directory/service.odin`. Restrict writes and full detail to those routes. Give bridge discovery and payload fetch separate read-only routes requiring an active bridge credential, matching enrolled owner and approved bridge device, checked on every fetch. Derive bridge identity from authentication as in `src/hub/transport/http/agent_handlers.odin` (`require_auth_or_bridge_token` requires an additional bridge-kind check here). Deny enrollment, user-only bearer, arbitrary instance bearer and revoked bridges at both bridge routes. Return Cache-Control no-store. Publish only owner-scoped invalidation and ID following successful commit.

## REQ-SKILL-0 · Use a credential from Bash

Propose `ham-ctl secrets run --id <id> -- <program> [args...]`. Run it from the agent’s Bash session. For example, check an encrypted local private key with its stored single-line passphrase:

```bash
set +x
./bin/ham-ctl secrets run --id "$credential_ref" -- openssl pkey -in encrypted-key.pem -passin stdin -check -noout
```

For discovery, expose `ham-ctl secrets list [--cursor ID] [--limit N]` via the instance-authenticated local RPC `agent.secrets.list`. The approved bridge requests an indexed metadata page for its authenticated owner and current vault. Apply the List query above, including its limit and exclusive cursor. Fetch only metadata and the context needed to open labels locally. Return items containing only the label and opaque reference, plus a page-level continuation cursor. Treat labels as non-sensitive display text. Never join, read or decrypt payloads during discovery. On lock request unlock. If labels are ambiguous ask which reference to use. If no suitable record exists, ask the user to create it in Settings → Vault and share its reference.

Only the opaque reference enters the task. The CLI resolves the program locally, starts it with an anonymous pipe as standard input, writes the exact UTF-8 bytes and closes the pipe at EOF. Preserve embedded and trailing newlines, with no added delimiter. Choose a trusted executable whose input format fits the value. The example consumes a single line. The program inherits the caller’s working directory. Always discard child stdout and stderr. Phase 0 has no output override. A trusted child needing to return data can write a named file of its choosing. Reflected credentials can persist in that file, so the child must select and validate the fields it writes.

The runner emits a fixed local message for each exit code. The first failed stage determines the result. After a successful stdin write and close, map any nonzero child exit or signal to code 26.

| Exit | Meaning |
|---|---|
| 0 | Child succeeded after credential delivery |
| 20 | Reference missing |
| 21 | Vault locked |
| 22 | Access denied |
| 23 | Child failed to spawn |
| 24 | Stdin delivery failed, including a broken pipe |
| 25 | Invalid invocation or malformed reference |
| 26 | Child failed, including a rejected form login |
| 27 | Lookup transport, envelope validation or authenticated open failed |

The CLI sends only the ID through an instance-authenticated local RPC. Validate the instance and bridge binding, fetch the sealed payload using the approved bridge identity and return ciphertext plus authenticated-opening metadata to the CLI. Open locally with the live bridge keyring via the existing agent.vault.get path. Validate bounds and context before spawning. Keep values out of command strings, shell expansions, argv, environment, temporary files and generic response formatters. Close unused pipe ends, handle early closure, reap the child on cancellation or write failure and wipe owned mutable plaintext buffers on every exit. Map lookup, locked, denied, spawn, write and child failures to fixed diagnostics. Never interpolate payloads or child diagnostics into errors.

Use the context-specific opener alongside the vault primitives in `src/ctl/vault_content.odin`. Keep shell xtrace off, including in child scripts, and disable consumer debug, verbose and request tracing. Never echo input, dump the environment, log request bodies, or paste values into prompts or chat. Report only the result. On lock ask for unlock, on missing ask for the reference, and on denial stop. Trusted Bash scripts and subprocesses can deliberately write secrets to files, terminals, network destinations or other descriptors. Child output suppression covers only its two ordinary output streams. A same-account agent can access the keyring. Lock or revocation cannot recall bytes already delivered.

## REQ-BRW-0 · Persistent bridge-local browser login

Resolve one absolute `HEIMDALL_BROWSER_PROFILE_DIR` from the bridge’s persistent per-registration data directory, outside instance run directories and worktrees. Create it for the service account with owner-only directory access or equivalent Windows ACL. Reject symlink traversal or unsafe ownership. Use the same value across restarts and agents on this registration, distinct paths across registrations. Add it to `bridge_prespawn_env` in `src/bridge/bootstrap_prespawn.odin` and propagate through `src/bridge/acp_runtime.odin`, `src/bridge/hub_runtime_client.odin` and the shell execution path in `src/bridge/bridge_shell_session.odin`; verify from the actual child in each supported mode. The path contains no key. Browser data contains live sessions. Keep it out of artifacts, backups shared with agents and transcripts.

The agent opens an installed compatible browser with the persistent profile and checks the application’s signed-in account. Reuse a matching session. If sign-in is required, the agent operates the browser throughout. The user supplies missing non-sensitive details in chat and adds sensitive inputs in Settings → Vault, returning only their references. Use headed mode when a usable graphical session exists. Without a display, use supported headless persistent mode for already-authenticated work or return display-required for interactive login. Never launch a disposable fallback profile silently. Use the browser’s native exclusive profile mechanism. When the browser reports a locked profile or hands off launch to an existing process, the calling tool must stop and report busy; never remove a live lock, clone cookies or attach to an unrelated running browser. Same bridge agents share account-level access. Browser logout or owner cleanup revokes local reuse independently of vault lock. Phase 0 requires neither package installation nor a debugging port.

### Form login with Puppeteer

For a trusted application's username/password form, the owner saves one JSON object with string fields `username` and `password` in the masked value field. The trusted Node script receives that object on stdin. Use the installed browser, profile and credential backend from owner setup. The example assumes an existing puppeteer-core installation, Chrome stable, the verified absolute profile path, a usable display and an application controlled by the owner at the illustrated origin. Adapt selectors and the signed-in marker to that application. Verify password saving is disabled before sending credentials. Stop if the agent cannot establish that condition. Disable protocol debug logging, crash uploads, screenshots, video, tracing and request recording during login. Keep browser and page diagnostics out of task output.

```bash
set +x
unset DEBUG NODE_DEBUG
./bin/ham-ctl secrets run --id "$credential_ref" -- node login.mjs
```

```javascript
import puppeteer from 'puppeteer-core';
import { readFileSync } from 'node:fs';
import { isAbsolute } from 'node:path';

const profile = process.env.HEIMDALL_BROWSER_PROFILE_DIR;
const login = 'https://app.example.test/login';
let browser;
try {
  if (!profile || !isAbsolute(profile)) throw new Error();
  browser = await puppeteer.launch({
    channel: 'chrome', headless: false, userDataDir: profile, pipe: true,
    dumpio: false, ignoreDefaultArgs: ['--password-store=basic', '--use-mock-keychain'],
  });
  const page = await browser.newPage();
  await page.goto(login);
  if (page.url() !== login) throw new Error();
  const { username, password } = JSON.parse(readFileSync(0, 'utf8'));
  if (typeof username !== 'string' || typeof password !== 'string') throw new Error();
  await page.type('#username', username);
  await page.type('#password', password);
  await page.click('button[type=submit]');
  await page.waitForSelector('[data-signed-in]', { visible: true, timeout: 15000 });
  if (new URL(page.url()).origin !== new URL(login).origin) throw new Error();
} catch {
  process.exitCode = 1;
} finally {
  await browser?.close();
}
```

Only use this example on a trusted form whose scripts and submission destination the operator has verified. The application and browser receive the values in memory. Report only the runner result. The profile retains the authenticated session. [Puppeteer launch options](https://pptr.dev/api/puppeteer.launchoptions)

### Sign in with Google

One trusted Puppeteer process owns the exclusive profile, tab and popup from launch through completion, including chat round trips. Start it as a managed local process independently of any credential invocation. For each requested reference, the controller starts a one-shot `ham-ctl secrets run` child that reads stdin and forwards the bytes directly to the waiting browser process over a private local pipe. Use an owner-only per-run directory and Unix-domain socket (or a current-user-only Windows named pipe), with a fresh single-use step identifier. Deliver bytes only while the same unexpired step and document are active. The forwarding child never launches or attaches to a browser. Close the pipe and release the browser on cancellation, timeout or controller failure.

The controller exchanges decisions and status with the agent through private per-run files written by atomic replacement. Each message carries the run ID and increasing step number. Accept a reply only for the outstanding step. Replies contain an account selection, vault reference, explicit allow/deny or cancellation. Status is one of `choose_account`, `need_password`, `wrong_password`, `need_code`, `device_pending`, `passkey_required`, `consent_pending`, `provider_blocked`, `expired`, `cancelled`, `failed` or `signed_in`. Map recognized accounts to configured non-sensitive aliases. For consent, report only the verified application label and scope names from a trusted local mapping. Stop on unknown consent details or unrecognized screens. Never copy page text, URLs, field values or diagnostics into status. Remove run files and endpoints on exit. Child stdout and stderr stay suppressed.

1. Open the relying application in the shared profile. Verify its origin and the intended signed-in account. If a suitable session exists, continue there. Otherwise select **Sign in with Google**. The agent controls the tab or popup throughout.
2. Verify the active credential document and its frame have the exact origin `https://accounts.google.com` before each sensitive entry or submission, including after navigation or an account switch. Stop on an unexpected origin, frame or destination. Use the same trusted Bash/Puppeteer runner and stdin contract as the form example wherever the provider permits this flow. Resolve only the reference needed for the current step. Keep password saving and diagnostic capture disabled.
3. Ask in chat when the account choice is ambiguous. For a missing password or supported one-time code, ask the user to enter it in Settings → Vault and return the reference. For an offered approval on the user’s own enrolled device, wait for the provider to confirm completion. A passkey may proceed only through a provider-supported authenticator available to the user for this ceremony. If the challenge needs interaction with the agent’s window, requires unavailable hardware, expires, or the provider blocks automation, stop and report the outstanding requirement. Never work around a provider block.
4. Before granting consent, describe the requesting application and requested permissions and wait for an explicit user decision. Stop on denial or cancellation. After the redirect, verify the expected relying-party origin, signed-in marker and intended account before reporting success. Keep codes, cookies, tokens and callback URLs out of chat and logs.

## REQ-FUT-0 · Later boundaries

A later policy layer can authorize an operation on a secret for a specified owner, bridge and agent until an absolute expiry; evaluate it at use time with revocation and trusted time. It needs independent design for existing general-purpose key access. No counts, grant records, cards, renewal or permission workflow ship in this slice. A future desktop service can identify an OS window and mediate capture and input with platform consent, focus and lifetime checks independently of browser vendor or debugging protocol. Streaming, remote input and capture are deferred.

## GPT-Sol implementation briefs and merge gate

1. **Envelope contract and persistence.** Own shared vault primitives, UI crypto helpers, SQLite migration, repository interface and implementation. Deliver vectors and transactional operations described above. Test migration from previous head and fresh DB. Seed multiple owners and vaults with at least 100k rows including a dominant owner. Inspect EXPLAIN QUERY PLAN for first/deep page, detail, update and delete. Require composite-key SEARCH, no scan or temporary sort; measure SQLite VM steps at first/deep cursors for a fixed page size and verify work stays proportional to page size plus tree seek. Race two edits and edit/delete from separate connections; exactly one conditional mutation succeeds.
2. **Owner and bridge endpoints** depend on 1. Own hub service, auth, route registration and invalidation. Exercise actual HTTP handlers with two owners, two bridges, approved/revoked devices, wrong principals, stale revisions/epochs, malformed oversized envelopes and replayed signatures. Verify foreign and missing responses match. At the metadata HTTP endpoint deny revoked bridge, enrollment, user-only and instance credentials. Reject owner overrides in query or body. A valid foreign-ID cursor is only an ordering boundary and returns at most the authenticated owner’s rows after that ID. Assert no payload fields and Cache-Control: no-store. Inspect captured responses and seeded storage for cleartext markers. Reset and rotate concurrently with writes.
3. **Owner UI** depends on 1–2. Own Settings → Vault navigation, signed endpoint client and editor. Test create, duplicate names, cursor paging, rename, replacement, stale edit/delete and retry after lost response. Exercise direct navigation, lock while loading, account switch and historical keys. Assert list responses omit payload, copy returns ID and persistent state contains no plaintext.
4. **Bridge discovery, lookup and CLI runner** depend on 1–2. Page through duplicate labels and verify stable reference ordering and bounds. Seed a foreign owner and attempt cross-owner listing, including a foreign cursor and a forged owner field. Assert denial of foreign access, no foreign metadata, metadata-index use, zero payload table reads and zero payload opens. Exercise the actual CLI with synthetic markers and an offline child fixture that checks length and digest via stdin, including multiline values and trailing newlines. Inspect child argv and environment for the marker. Have the child reflect input to both output streams and exit successfully or unsuccessfully. Scan CLI output, shell transcript, result events and hub/bridge logs for markers and encoded equivalents. Test lock, revoke, missing and malformed references before launch, spawn failure, early pipe close and cancellation. Verify descriptors close and children are reaped. Assert each documented runner code (0 and 20–27) with its fixed message. Include child exit 21 mapping to 26, a forced pipe-write error mapping to 24 and an actual locked vault mapping to 21.
5. **Browser convention** can start independently. Own persistent path, launch/shell environment, busy handling and browser instructions. Exercise two agents, restart, two bridge registrations, occupied profile, crashed launcher with browser still running and no-display paths. With an already-installed supported browser, sign into a local test page, close, reopen from agent B and verify session continuity. Record platform and browser. Report unavailable platform coverage explicitly.
6. **Skill distribution and integration** depend on 3–5. Add `src/prompts/skills/credential-and-browser-use/SKILL.md`, reference it from bootstrap, regenerate with `odin run tools/gen_static_skills -- src/prompts/skills src/hub/service/agent/static_skills_gen.odin`. Verify `render_agent_manifest` in `src/hub/service/agent/agent_service.odin` and `bridge_bootstrap_render_skill` in `src/bridge/bootstrap_skill.odin` materialize the skill for supported providers. Run repository package checks for touched Odin packages, `npm test`, `npm run build` and `npm run test:e2e:vault`. Demonstrate owner creation through actual Settings, ID-only agent invocation, successful credential-fed child exit, lock/refusal, edit/conflict, delete/missing and profile reuse. Exercise the documented Puppeteer flow with synthetic fields on a local test form, reopen the profile and verify the authenticated marker. Check captured CLI, bridge and fixture logs for both markers and confirm no screenshot, trace or profile artifact was produced. Redirect the fixture login to a second local origin before field entry. Assert runner exit 26 and verify neither input received a keystroke or value on the redirect target. Teach the skill to discover a suitable reference with secrets list and ask for vault creation on a miss. Teach the skill the account-choice, vault-reference, provider-challenge and consent steps above. Use local relying-party and provider fixtures with a test-only expected provider origin. Exercise session reuse without a lookup, account selection, staged credential and code entry via references, explicit consent and denial, and unavailable passkey or blocked-provider outcomes. Verify no sensitive input reaches a redirected page or unexpected frame, and no success is reported until the relying party confirms the intended account. Keep one browser PID and profile lock across a simulated chat round trip for a later code reference and a separate consent decision. Verify the forwarding child delivers only to the pending step. Reject stale or replayed replies, clean up on timeout, and assert each documented status separately. Scan status, reply files and logs for synthetic secret markers. Use synthetic values exclusively. Attach sanitized outcomes and query plans for merge review.

Use by opaque ID needs no label decryption. Discovery decrypts one bounded page of non-sensitive labels locally and can traverse every page. Splitting name and payload reduces read exposure. Product implementation starts only after independent review and approval.

## Enforced boundaries and known bypasses

| Boundary | Enforcement or convention | Required negative check |
|---|---|---|
| Hub ciphertext fetch | Bridge-kind authentication, owner binding and current approved bridge device. The local dispatcher in `src/bridge/agent_api.odin` (`bridge_agent_route` returning `Bridge_Agent_Route`) exposes the instance-authenticated metadata list and ciphertext lookup. | Assert the internal HTTP fetch has no raw/relay mapping. Send an instance token directly and through the relay path and expect denial before data access. |
| Ordinary output | The RPC returns sealed bytes. The runner emits a fixed local result. Credential AAD makes generic vault open fail authentication. | Feed the same synthetic credential vector to `ctl_vault_open`, `ctl_decrypt_json_value` and `bridge_decrypt_embedded_vault_tokens`. Verify explicit failure for direct open and zero plaintext in the recursive/embedded outputs, including locked paths. |
| Same OS account | `agent.vault.get` in `src/bridge/agent_api.odin` supplies every local agent the whole multi-epoch keyring. `src/ctl/vault.odin` documents this trust. The OS account can read the on-disk bridge credential, fetch ciphertext as the bridge and use the public credential context with those keys. | Treat every same-account agent as trusted. The skill directs ordinary use. Strong isolation would require a different principal and key distribution model. |

## Data flow and storage lifecycle

1. Create: unlocked owner UI → seal name and credential value at revision 1 → signed POST → hub checks owner, root namespace and epoch → insert both rows atomically → UI shows ID.
2. List: owner UI → signed cursor GET → indexed metadata page → decrypt only displayed labels locally.
3. Edit/delete: signed single-record GET → local edit and reseal → conditional PUT or DELETE → atomic two-table update or cascade. Conflict triggers refetch.
4. Use: agent supplies ID and local command → instance-authenticated lookup → indexed bridge ciphertext fetch → authenticated CLI open → child stdin → local exit result. Test lock and revocation before child launch.
5. Lock: UI session generation changes and pending decrypt completions are discarded. A bridge lock removes its live keyring. A UI-only lock does not lock an independently unsealed bridge. An already started child can retain its input.

In each mutation transaction read the owner’s directory row and root device via `root_device_id` and owner. Derive the namespace from the first eight SHA-256 bytes of the decoded root signing public key, rendered as lowercase hex. Reuse `vault_id_from_root_sign_pub` as used in `src/lib/vault/directory_verify.odin`; include a TS comparison against `vaultIdFor`. Compare the directory’s `current_epoch` and derived vault ID before mutation. Persist no additional current-ID cache. Task 1 adds a durable reset queue with unique (owner_id,vault_id) and integer queue ID. Hook `vault_execute_reset_sqlite` before directory deletion, recording the old namespace in the same transaction. On hub startup and periodic maintenance process the oldest queue item by ID, deleting at most 100 parent rows selected by owner/vault/ID order in one transaction. Remove the queue item only when empty. Cascade payload deletion. Interruption/retry and immediate new genesis must leave the new namespace intact.

## Browser operating conditions

Anchor the default under `bridge_os_default_data_dir` in `src/bridge/os_platform_unix.odin` and `src/bridge/os_platform_windows.odin`, then use a stable registration-specific child and browser-profile leaf. Honor the configured bridge data root first. Native browser profile ownership spans the browser process lifetime, including a launcher crash. Profile support is a tool convention; Phase 0 adds no browser CLI. Independently launched tools must use the advertised path and handle busy without interacting with someone else’s window.

The launching tool tests the actual child session. Linux needs reachable Wayland or X11 using the service’s inherited WAYLAND_DISPLAY/XDG_RUNTIME_DIR or DISPLAY/XAUTHORITY. Windows needs the interactive user desktop in the same session; macOS needs an active Aqua login for the launch user. A variable alone is insufficient. Preserve the service session’s legitimate display and DBus context through supported launch paths; never synthesize another user’s desktop credentials. If graphical initialization fails, report the reason and follow the headless rule above.

Use the same browser family, OS account and cookie encryption backend for setup and reuse. Chromium on Linux needs the original Secret Service/libsecret or KWallet backend available and unlocked with matching session bus and backend selection. On macOS the same accessible login Keychain is required; on Windows the same user/DPAPI context is required. Never silently add `--password-store=basic` or change backend. Missing key store means report session unavailable and ask for restoration. Task 5 tests headed sign-in and subsequent service/headless cookie-backed access with the same store, then simulates an unavailable bus/keychain and checks the profile and encrypted cookies survive. Record separately any platforms lacking an interactive test fixture.

## Worker interface and file ownership

Paths described as new are proposed additions. The existing migration series ends at 264 in this checkout.

| Brief | Files and contract |
|---|---|
| 1 | New `src/hub/repository/sqlite/migrations/265_credential_secrets.sql`, `src/hub/repository/iface/credential_secret_repo.odin`, `src/hub/repository/sqlite/credential_secret_repo_sqlite.odin`, `src/lib/vault/credential_envelope.odin`, `src/ui/utils/credentialEnvelope.ts`. Own migration registration, reset hook and queue worker. Expose create/page/detail/CAS edit/delete and read-only payload lookup with owner and namespace required. Compare cold-cache SQLite page-cache misses on identical label pages with short versus maximum payloads; list must access neither payload table nor its overflow pages. |
| 2 | New `src/hub/service/credential_secret/service.odin` and `src/hub/transport/http/credential_secret_handlers.odin`; register in `src/hub/app/wiring.odin`. Consume task 1 interface. Public collection GET/POST at `/api/v1/vault/secrets`; item GET/PUT/DELETE at `/api/v1/vault/secrets/{id}`. Use signed expected revision in PUT body and DELETE query. Internal bridge metadata GET `/api/v1/bridge/credential-secrets` and payload GET `/api/v1/bridge/credential-secrets/{id}/payload`. Detail/use response includes ID, vault ID, epoch and revision for authenticated opening. |
| 3 | New `src/ui/components/settings/CredentialSecretsPanel.tsx` and `src/ui/api/endpoints/credentialSecrets.ts`; own Settings routing and modal integration, consume task 1 seal/open and task 2 public routes. |
| 4 | New `src/bridge/credential_secret_lookup.odin` and `src/ctl/credential_secrets.odin`. Register local-only `agent.secrets.list` and `agent.secrets.lookup` in `src/bridge/agent_api.odin`; command and help in `src/ctl/agent_mode.odin` and `src/ctl/help.odin`. Consume task 1 envelope and task 2 internal GET. Keep process creation and stdin delivery local to the invoking CLI. |
| 5 | Own the platform data-root, prespawn and shell paths cited above and add `docs/browser-profile.md`. Interface is one inherited path and documented browser-native busy handling. Test real child environment and OS cookie-store cases. |
| 6 | Own the skill, generated catalog, bootstrap reference and integration fixtures under `tests/`. Consume public UI, CLI and browser conventions. Verify the actual local CLI successfully checks a fixture key with its synthetic passphrase through the bridge, then verify absence of synthetic secret values in output and logs. |

## Alternatives and blockers

The hub indexes opaque IDs and stores encrypted labels. Authorized bridge discovery can read all labels across successive pages. Environment/argv injection gives generic children ambient access and creates additional logging surfaces. Generic HTTP response redaction cannot reliably handle reflection or arbitrary encodings. Anonymous stdin delivery supports ordinary local programs that accept credential input. Browser autofill would require field, origin and navigation policy. A bridge-only OS keychain for application credentials would need a second synchronization and recovery model. Native cookie keychains still serve their existing browser function. There are no known design blockers. Platform cookie retention and actual launch environment remain implementation acceptance gates.
