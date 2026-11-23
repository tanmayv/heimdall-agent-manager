# Bridge installer contract (`install.sh` / `install.ps1` / `ham-bridge setup`)

Status: **spec, for review** (chain `chain_18ea9cf21732bfc6`, task T1). Implemented by
T2 (`ham-bridge setup`), T3 (scripts) and tested by T4. Written against `v0.5.74`
(`60c3af8b`); `file:line` references are to that tree.

Requirements served: `REQ-INSTALL-1` (headless one-liner), `REQ-INSTALL-2` (idempotent,
unattended, re-enroll if needed, healthy bridge untouched), `REQ-INSTALL-3` (bootstrap
only, never a second update path), `REQ-OS-1` (Linux incl. Fedora Atomic, macOS, Windows).

## 1. The one-liners

```bash
# Linux, macOS, Termux
curl -fsSL https://install.ninjy.ai | bash -s -- --hub https://hub.example.com
# same, configured by environment (no `-s --` needed)
curl -fsSL https://install.ninjy.ai | HEIMDALL_HUB=https://hub.example.com bash
```

```powershell
# Windows PowerShell 5.1 / PowerShell 7, no admin rights
$env:HEIMDALL_HUB = 'https://hub.example.com'; irm https://install.ninjy.ai/ps1 | iex
# or with parameters
& ([scriptblock]::Create((irm https://install.ninjy.ai/ps1))) -Hub https://hub.example.com
```

The same two files are also attached to every release as assets
(`.github/workflows/release-local-binaries.yml`, copy step ~`:961`), so a pinned copy can
be fetched from `https://github.com/tanmayv/heimdall-agent-manager/releases/download/<tag>/install.sh`.

The command is safe to run any number of times. Every run ends in one of the states
in §3 and exits with one of the codes in §4.

## 2. Who decides what

| Layer | Does | Never does |
|---|---|---|
| `install.sh` / `install.ps1` | Parse flags and env (§5); check prerequisites; refuse root (`install.sh:129`); resolve a release tag; download this target's bundle and `SHA256SUMS` (later also the signed manifest, T3b); verify; unpack to a temp dir; run the bundle's `ham-bridge setup --headless …` with stdin detached; delete the temp dir; exit with `ham-bridge`'s exit code unchanged. | Inspect, stop, start, copy into or delete anything under an instance; read credentials; decide whether a bridge is healthy, enrolled or out of date; prompt. |
| `ham-bridge setup` (`src/bridge/setup_cmd.odin`, engine `src/lib/bridgesvc/setup.odin`) | **All detection and all action, one implementation for every OS**: classify the instance (§3), choose the minimal action, run it in the existing transaction (Lock → Stage → Binaries → Config → Ports → Service → Enroll → Extensions → Start → Verify, `setup.odin:22-33`) with rollback, print the outcome, return the exit code. | Prompt when stdin is not a terminal or `--headless`/`--json-progress` is set (`enroll_account_replace.odin:94-97`). |

Why the scripts stay thin: the classification needs the credential, the re-enroll marker,
the service manager and the runtime status — all already modelled in `bridgesvc`
(`status.odin:42-123`). Doing it twice (bash + PowerShell) is how the four copies of
release resolution diverged (report §2.2). The script always runs the **downloaded**
`ham-bridge`, never the installed one, so an old install with an old (or broken) setup is
still classified by current logic. The cost is one bundle download per run; accepted.

## 3. State table

"Instance" = one `(hub, profile)` pair, i.e. one service name
(`bridgesvc.profile_from`, `bridgesvc.odin:172-191`). Classification happens after
**Lock** and before any mutation; the label is printed and, with `--json-progress`, emitted
as `{"step":"detect","state":"ok","message":"<label>"}`.

Detection inputs (all per instance, all existing today):
service registered (`bridge_service_registered`), service running / runtime pid,
`bin/ham-bridge` present, credential in `state_dir/<TOKEN_FILE>`
(`bridgesvc.credential_bridge_id`), re-enroll marker `needs-reenrollment.json` that
applies to the current credential (`status.odin:67-110`), saved hub (`hub-url` /
`config.toml`), leftover `.staging` or a held lock, installed version from
`runtime-status.json` / `bin/ham-bridge --version`.

Unless a row says otherwise: **no TTY needed** (stdin is `/dev/null` under `install.sh`,
`install.sh:176`; `--headless` disables every prompt), output goes to stdout as today's
`[ nn%] step … ok` lines (`setup_cmd.odin:160-176`), the script's own lines are
`[INFO] / [OK] / [ERROR]` on stderr, and the last stdout line is the **final line** shown.

| # | Starting state (detection) | Action (pre-Phase 2) | Exit | Final line (stdout) |
|---|---|---|---|---|
| S1 | **Nothing installed**: no service, no `bin/`, no credential for this instance. | Full transaction: stage, install `bin/`, write config, allocate ports, register service, enroll (device flow, §6), extensions, start, verify connected. | 0 | `Installed <service> v<ver>, enrolled as <bridge_id>, connected to <hub>.` |
| S1a | S1, but enrollment is not approved before the code expires (incl. reissues) or is denied. | Binaries, config and service stay installed; service is **not** started; profile is `not_enrolled`. Re-running the one-liner continues at S3. | 4 | `Installed <service> v<ver> but not enrolled: <reason>. Run the same command again to enroll.` |
| S2 | **Installed, enrolled, healthy**: service registered and running, `bin/` present, credential present, no applicable re-enroll marker, saved hub = requested hub, no `--version`, or `--version` equal to the installed version. | **Nothing.** No stop, no file written, no service re-render, no extension sync, no download beyond the script's bootstrap. Waits up to the verify timeout (45 s, `setup_cmd.odin:26`) for `connected`, read-only. | 0 | `<service> v<ver> is already installed, enrolled as <bridge_id> and connected; nothing changed.` If still not connected after the wait: same, with `…running but not connected to <hub> (hub unreachable?); nothing changed.` and a `warning` event — re-installing cannot fix a hub outage. |
| S3 | **Installed, not enrolled**: `bin/` + service present, no credential (e.g. S1a, or the credential file was deleted). A re-enroll marker with reason `credential_missing` (enrolled but tokenless, `status.odin:67-69`) lands **here**, not in S4: its `bridge_id` is passed as `--reuse-bridge` and the marker is cleared on success. | Keep binaries. Re-render service only if its file differs, run **Enroll**, then Start + Verify. | 0 / 4 | `Enrolled <service> as <bridge_id>; connected to <hub>.` / as S1a. |
| S4 | **Installed, enrollment invalid**: credential present **and** an applicable `needs-reenrollment.json` (reason `revoked`, `refresh_rejected` or `vault_key_timeout`; `credential_missing` is S3), written by the running bridge when the hub refused it (`hub_quiescence.odin:59`). Also: hub answers 401/403 to the credential during detection. This includes **"hub changed"** in the T0 sense: same hub URL, but the hub behind it no longer accepts the credential (reset, redeployed, re-keyed). | Keep binaries and data. Enroll with `--reuse-bridge <current id>` (today's `--reenroll` path, `setup_cmd.odin:443-444`) so the bridge keeps its identity if the approver allows; clear the marker on success; restart + verify. **New in T2:** the marker triggers this without the caller passing `--reenroll`. | 0 / 4 | `Re-enrolled <service> (was <old_id>, reason <reason>) as <bridge_id>; connected.` |
| S5a | **Other hub URL**: an instance exists for hub A; the run asks for hub B. | Different service name ⇒ S1 for a **new, separate** instance. Hub A's instance is not read or touched, and is **not** moved or re-enrolled to B (user decision, §3.1). | as S1 | as S1 |
| S5b | **Name collision**: sanitized hub names collide, so the requested service's saved hub ≠ requested hub (`setup_cmd.odin:300-308`). | Refuse before any stop or write. | 5 | `[ERROR] Profile <service> belongs to hub <A>, not <B>; pass --profile <name> to install a separate profile.` |
| S5c | **Other profile**: `--profile X` while only the default (or another) profile exists. | S1 for profile X; others untouched. | as S1 | as S1 |
| S5d | **Same profile, other Ninjy account** (a run that would enroll a new bridge into an enrolled profile, `--new-bridge`/`--reuse-bridge <other>`). | Headless default stays as today: install into the next free `account-N` profile and leave the enrolled one as is (`setup_cmd.odin:124-149`). `--replace-other-account` is required to replace. | as S1 | `Installing this Ninjy account as a separate profile "account-2" …` then as S1. |
| S6 | **Service missing or stopped**: `bin/` + credential OK, service file absent/unregistered, or registered but not running (and no re-enroll marker). | Keep binaries and credential. Re-register the service (render + register), Start, Verify. Never re-enroll for this. | 0 / 1 | `Repaired <service> (service <registered|started>); connected to <hub>.` On failure the previous state is restored: `ham-bridge setup FAILED at step "<step>"; the previous install was restored.` (exit 1). |
| S7 | **Partial / interrupted install**: leftover `.staging`; `bin/` missing (with or without `bin.bak*`); lock held by a dead pid; service registered but `bin/ham-bridge` missing. | Break a dead owner's lock (Stale_Lock), discard staging (Partial_Install, `setup.odin:79-98`), install `bin/` from the downloaded bundle (a `bin.bak*` is **not** trusted as the source), then continue as S1/S3/S6 for the remaining steps. Credential and data are kept. | 0 / 1 / 4 | `Recovered an interrupted install of <service>: <what was fixed>; …` then the S1/S3 line. |
| S7a | **Busy**: lock held by a **live** setup/update process. | Nothing. | 6 | `[ERROR] Another setup or update of <service> is running (pid <pid>); try again when it finishes.` |
| S8a | **Version skew, no `--version`**: S2 with installed ≠ the release the script downloaded (newer **or** older). | Treated as S2: **nothing changes**. Updates belong to the update path (today `ham-bridge update` / auto-update; after Phase 2 the supervisor). | 0 | S2 line, plus `(installed v<x>; this installer carried v<y>; updates are not done by the installer)`. |
| S8b | **`--version X` newer than installed** (any S2–S7 state). | Pre-Phase 2 only: replace `bin/` with X through the existing transaction (today's behaviour; it is the documented `ham-bridge update --version` equivalent). Repairs from S3–S7 are done in the same run. | 0 / 1 | `Updated <service> v<old> → v<X>; connected.` |
| S8c | **`--version X` older than installed.** | Refuse unless `--allow-downgrade` is also passed (`REQ-CHAN-1`: no silent downgrade; headless cannot confirm). With it: as S8b. | 5 | `[ERROR] <service> runs v<old>, newer than requested v<X>; pass --allow-downgrade to downgrade.` |
| S9 | **Rollback incomplete** (any row whose transaction failed and could not restore, `setup_cmd.odin:315-320`). | Stop; nothing further. | 7 | `ham-bridge setup FAILED at step "<step>"; rollback incomplete: <reason>.` |

### 3.1 "Hub changed" (T0 re-enroll trigger)

The T0 decision lists "hub changed" as a reason to re-enroll. The user confirmed
(2026-11-23, answer to the T1 review) that it means: **the same hub URL whose hub no longer
accepts the bridge's credential** — handled by S4, re-enrolled in place, keeping binaries,
ports, data and (if the approver allows) the bridge id. A **different hub URL** is a new
instance (S5a), never a move: an instance is keyed by `(hub, profile)` (service name,
`bridgesvc.odin:172-191`) and its keystore items are scoped by the canonical hub
(`src/bridge/keystore_scope.odin:8-21`), so moving it would mean migrating credentials
across hubs. The old instance keeps running until the user uninstalls it
(`--uninstall --hub <A>`). No `--move-to-hub` flag exists.

Notes:

- Rows combine: e.g. "service stopped + credential revoked" is S4 + S6 in one run; the
  exit code is that of the last step that ran.
- Steps a row does not need are reported as `skipped` (existing event state), so
  `--json-progress` consumers (Electron) see the same ten steps in every row.
- Today (`v0.5.74`) S2, S4, S6 and S8a **re-copy binaries and re-render the service on
  every run** (`setup_cmd.odin:335-402`) and S4 needs an explicit `--reenroll`
  (`setup_cmd.odin:151-158`). Closing these gaps is T2's work.
- S8a/S8b use the bundle's own version (`contracts.APP_VERSION`) and the installed
  version; versions compare as SemVer.

## 4. Exit codes

Shared by both scripts and `ham-bridge setup`. The scripts use 2 and 3 for their own
failures and otherwise return `ham-bridge`'s code unchanged (`install.sh:172-178`,
`install.ps1:111-112`).

| Code | Meaning | Re-run? |
|---|---|---|
| 0 | Done: installed, repaired, re-enrolled, updated with `--version`, or nothing to do. | — |
| 1 | Setup failed; the previous state was restored (and restarted if it was running). | after fixing the cause |
| 2 | Usage error: unknown/missing value, no `--hub`, invalid profile, root user. | after fixing the flags |
| 3 | Bootstrap failure, nothing touched: unsupported OS/arch, missing `curl`/`tar`/`sha256sum`, release not found, download failed, checksum (later: signature) mismatch. | yes |
| 4 | Installed but not enrolled (approval not given in time or denied). | yes — continues at S3 |
| 5 | Refused: needs an operator decision (profile owned by another hub, downgrade without `--allow-downgrade`). | with the named flag |
| 6 | Busy: another setup/update holds the instance lock. | yes, later |
| 7 | Rollback incomplete; manual repair needed (message names what is left). | no |

Today `ham-bridge setup` returns 1 for every failure (`main.odin:117-118`) and the
scripts return 1 for their own failures (`install.sh:28`, `install.ps1:115`); T2/T3
move them to this table.

## 5. Flags and environment variables

Flags win over environment variables: an env var is only a default, used when the
option is absent. Exactly one value per option reaches `ham-bridge`. In `install.ps1`
the env var is the parameter default (`install.ps1:24-26`), and a `--hub`/`--profile`/
`--name`/`--version` (or `--hub-url`) form arriving through pass-through would today be
appended **after** it (`install.ps1:100-107`), giving `ham-bridge` two values. T3 must make
`install.ps1` take those forms out of `$Rest` and bind them to `-Hub`/`-Name`/`-Version`
itself (overriding the env default) before building argv; the same rule already holds in
`install.sh`, whose own parser consumes them. Names are identical in both scripts; PowerShell
spells the same option as a PascalCase parameter, and every `--flag` form is also
accepted by `install.ps1` because unknown arguments pass through to `ham-bridge`
(`install.ps1:35,107`).

| Option (`install.sh`) | `install.ps1` | Env var (both) | Meaning |
|---|---|---|---|
| `--hub URL` (alias `--hub-url`) | `-Hub` (alias `-HubUrl`) | `HEIMDALL_HUB` | Hub API origin. **Required.** |
| `--profile NAME` (alias `--name`) | `-Name` (alias `-Profile`) | `HEIMDALL_BRIDGE_NAME` | Profile name, `[a-z0-9][a-z0-9-]{0,30}`; default profile when empty. |
| `--version TAG\|latest` | `-Version` | `HEIMDALL_VERSION` | Release to bootstrap from. Default `latest` (resolution: §5.1). On an existing instance: §3 S8, §7. |
| `--allow-downgrade` † | `-AllowDowngrade` † | — | Permit S8c. Deliberately no env var: a downgrade must be visible in the command. |
| `--bundle FILE --checksum-file FILE` | `-Bundle -ChecksumFile` | — | Use an already-downloaded bundle (desktop apps, air-gapped); verified first. |
| `--new-bridge` | `-NewBridge` | — | Enroll as a new bridge. |
| `--reuse-bridge ID` | `-ReuseBridge` | — | Enroll reusing bridge `ID`. |
| `--reenroll` | `-Reenroll` † | — | Force re-enrollment of a healthy instance (S2 → S4 path). Not needed for S3/S4. |
| `--separate-account` / `--replace-other-account` | `-SeparateAccount` / `-ReplaceOtherAccount` † | — | S5d choice. |
| `--json-progress` | `-JsonProgress` | — | Machine-readable progress (`docs/bridge-setup-progress.md`). |
| `--interactive` | `-Interactive` | — | Drop `--headless`: open the approval page in a local browser and allow terminal prompts. Not for unattended use. |
| `--uninstall` | `-Uninstall` | — | Run `ham-bridge uninstall` instead (its own flags pass through, e.g. `--purge --yes`). |
| `--help` | `-Help` | — | Usage, exit 0. |

### 5.1 Resolving `latest`

`latest` = the **highest SemVer** release that is promoted (not draft, not prerelease)
**and** carries both `SHA256SUMS` and this target's bundle
(`heimdall-local-<target>-<tag>.tar.gz` / `.zip`). The scripts page
`GET /repos/tanmayv/heimdall-agent-manager/releases?per_page=100` **to exhaustion**
(follow `Link: rel="next"`), as T7 does for the other readers. This keeps today's
per-target asset check (`install.sh:40-86`, `install.ps1:68-77`) and removes the
first-30 limit (report F9).

`GET /releases/latest` is **not** used: GitHub returns the release flagged `make_latest`
(by default the most recently created non-prerelease), which after a promoted backport
can be lower than the highest SemVer and is not checked for this target's bundle.
Consistent with Q2 (newest = highest SemVer).

If any page fails (network, rate limit, non-list body) the result is incomplete: the
script stops with exit 3 and `[ERROR] Cannot list all releases from GitHub (<reason>); pass
--version TAG.` It never picks from a partial list. If no release qualifies: exit 3,
`[ERROR] No promoted release has a <target> bundle. Pass --version TAG.`

† New: `--allow-downgrade` is added to `ham-bridge setup` (T2); the marked PowerShell
parameters are added to `install.ps1` (T3). Until then the `--flag` form passes through.

Justified differences:

- **Spelling** (`--hub` vs `-Hub`): PowerShell parameter binding only binds `-Name` style;
  the `--hub` form still works through pass-through, so documentation can show one form.
- **`-Name` is the canonical PowerShell parameter** (with `-Profile` alias) because
  `$Profile` is an automatic variable in PowerShell; bash uses `--profile` with `--name`
  as alias. Both map to `ham-bridge --profile`.
- **Environment variables matter more on Windows**: `irm … | iex` cannot pass parameters,
  so `HEIMDALL_*` is the only way to configure that form. `install.sh` must read the same
  three (today it reads only `HEIMDALL_BRIDGE_NAME`, `install.sh:130`; T3 adds
  `HEIMDALL_HUB` and `HEIMDALL_VERSION`).
- **Termux** is detected by `install.sh` only (`install.sh:103-110`); Windows has a single
  target (`windows-amd64`, `install.ps1:39`).

No other environment variable changes installer behaviour. `HEIMDALL_*` variables not
listed here are ignored by the scripts (test harnesses strip them,
`tests/test_installer_clean.py:68`).

## 6. Headless enrollment: how it is authorised without a browser

Enrollment (S1, S3, S4) uses the existing device grant with a hub-blind pairing code
(`src/bridge/enroll_device_flow.odin:1-33`):

1. `ham-bridge enroll --headless` (run by setup, `setup_cmd.odin:446-454`) requests a
   device code from the hub and prints a **stable approval URL** (no per-request data)
   and a **secret pairing code** (`enroll_device_flow.odin:1293-1312`). With
   `--json-progress` the URL and code are also one JSON event (`:467-480`).
2. A person types the pairing code at that URL on **any other device already signed in to
   the same Ninjy account** (phone, laptop). No browser, display or TTY is needed on the
   machine being installed; `--headless` never opens one (`:1315`).
3. The bridge polls the hub with the device code and PKCE verifier — polling is the only
   completion channel; there is no inbound port or callback (`:20-23`). The approving
   browser verifies a MAC over the bridge's identity and keys derived from the pairing
   code, so a substituted hub is detected.
4. Expired codes are reissued up to `BRIDGE_ENROLL_MAX_REISSUES = 2` times (`:458`);
   after that setup ends with exit 4 (S1a) and the next run continues.

The authorisation is the human approval of that pairing code by the account owner. There
is no pre-shared enrollment token and this spec does not add one: a fully unattended
first enrollment (no human approval at all) is **out of scope**. "Unattended" in
`REQ-INSTALL-2` means no TTY and no prompt on the target machine; a bridge that is already
enrolled and healthy (S2, S5–S8a) needs no approval at all.

## 7. Hand-off rule for existing instances (`REQ-INSTALL-3`)

The installer is a bootstrap. On an instance that already exists it must not become a
second update path.

**Before the supervisor exists (now → end of Phase 1):**

- Without `--version`, a healthy instance's version is **never** changed (S2, S8a). Repairs
  (S3, S4, S6, S7) keep the installed binaries unless `bin/` itself is missing or partial.
- With `--version X` the script behaves as `ham-bridge update --version X` does today:
  the same setup transaction replaces `bin/` (S8b; S8c needs `--allow-downgrade`). This is
  today's path P5 (report §2.2), kept working until Phase 4 deletes it.

**After Phase 2 (instance has a launcher, a supervisor and an ownership record):**

- The script still only downloads, verifies and runs `ham-bridge setup`. Setup detects the
  supervisor-managed instance and **never writes `releases/`, `current` or `previous`**,
  and never stops the service to swap files.
- S3, S4 (enrollment) and S6 (service registration pointing at the launcher) are still done
  by setup: they change configuration, not the release.
- `--version X` (and `--allow-downgrade`) becomes an **intent** enqueued to that
  instance's supervisor — `{op_id, instance_id, action: "install_version", version: X,
  expires_at, actor: "installer"}` (format fixed by T9) — and setup waits for the
  journal to reach `committed` or a terminal failure, printing its states. Exit 0 on
  `committed`, 1 on `rolled_back`, 7 on `rollback_failed`.
- Without `--version`, no intent is enqueued: the supervisor follows its channel by itself.
- If the supervisor does not accept the intent (not running, not reporting healthy), setup
  first repairs the service (S6) so the launcher starts it. Recovering a supervisor that
  cannot start at all (report §9 risk) is defined by T9 and must run the **same engine
  code** under the instance lock and journal, not a separate copy in the scripts.
- A partial install on a supervisor-managed instance (S7 after Phase 2: the `current`
  release tree missing or incomplete, launcher present or not) is **not** repaired by
  copying from the bundle. It is the same case as the unstartable supervisor above and is
  deferred to T9's recovery procedure (same engine, instance lock, journal). Setup still
  breaks a dead owner's lock, repairs the service registration (S6) and prints
  `[ERROR] <service>: release tree incomplete; recovery: <T9 command>` with exit 1 until T9
  defines it.
- A legacy (non-converted) instance found after Phase 2 is converted by setup (Phase 2
  conversion transaction), never updated by the script.

## 8. Out of scope here

Signed-manifest verification in the scripts (T3b → T5), the engine itself (T9–T15),
Electron flows (§6.9 of the report), uninstall semantics beyond the pass-through, and
Nix / home-manager installs (Phase 4 adoption).
