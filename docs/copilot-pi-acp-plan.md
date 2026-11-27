# Copilot and Pi support over the bridge ACP runtime

Plan for task `task_18e97c6373fb3428`, requirements revision 1, based on repository `f2ec7361f` and live checks on 2026-11-19. Copilot can use its native ACP server. Pi needs the separate upstream ACP adapter and additional compatibility work before fleet use. Implement a small allowlisted provider descriptor layer around the existing transport, dispatcher, inbox, permissions and chat pipeline. Deliver Copilot first; gate Pi on the session-store and permission limitations below. This task changes documentation/evidence only and proposes future work; it creates no implementation tickets or production changes.

## 1. Exact launch and package pins

| Provider | ACP launch after installation | Pins evaluated | Launch distinction |
| --- | --- | --- | --- |
| Copilot | `<resolved-copilot> --acp --stdio` | `@github/copilot@1.0.114`; matching platform package at `1.0.114` | Native ACP, no Claude-style adapter. Set `COPILOT_AUTO_UPDATE=false` so cached updates cannot replace the pinned runtime. |
| Pi | `node <adapter-root>/node_modules/pi-acp/dist/index.js` | `pi-acp@0.0.34` with `@earendil-works/pi-coding-agent@1.1.0` | Adapter launches `<resolved-pi> --mode rpc --no-themes`; set protected `PI_ACP_PI_COMMAND=<resolved-pi>` and `PI_ACP_ENABLE_EMBEDDED_CONTEXT=true`. |

The Pi executable pin deliberately matches the installed, version-checked Nix CLI used in the final probes. The similarly named legacy `@mariozechner/pi-coding-agent` and the many Pi adapter forks are different distributions. The [ACP registry pins upstream svkozak/pi-acp at 0.0.34](https://github.com/agentclientprotocol/registry/blob/main/pi-acp/agent.json). Its [versioned README describes the RPC bridge](https://github.com/svkozak/pi-acp/blob/v0.0.34/README.md). Copilot's [official ACP documentation specifies the native stdio launch](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server).

Candidate install commands in private, staged runtime roots:

```bash
npm install --prefix <copilot-stage> --save-exact --ignore-scripts --no-audit --no-fund @github/copilot@1.0.114
npm install --prefix <pi-adapter-stage> --save-exact --ignore-scripts --no-audit --no-fund pi-acp@0.0.34
```

Provision Pi CLI 1.1.0 through the host package manager or a separately pinned install; do not overwrite the operator's global Pi. An explicit profile binary override resolves to that provider's underlying CLI, never to another provider or arbitrary adapter.

### Install and integrity contract

Retain staging, advisory locks, bounded probes, atomic promotion, status reporting and catalog-etag checks from the Claude installer. Key runtime roots/locks/probe markers by provider plus descriptor revision and version tuple. A marker must bind package integrity, underlying CLI version, platform and probe environment requirements; a Claude marker cannot validate Copilot or Pi.

Use reviewed lockfiles with exact transitive versions/integrities and `npm ci --ignore-scripts` in the implemented installer. The exploratory commands above generated a lock; a top-level version pin alone does not freeze ranged dependencies. Verify package identity, version, entrypoint, lock integrity and trusted tarball bytes before promotion. These registry SHA-512 values were retrieved during this task:

| Package | Expected SRI |
| --- | --- |
| `@github/copilot@1.0.114` | `sha512-qhiUzWGAu3v9jRMU62YFpoI/x9/sQJbylUU2rNrKpTgJSw+jRX7eee0RKf/ZC/FfOPtuACpXWNBQrf08WhVEEw==` |
| `@github/copilot-linux-x64@1.0.114` | `sha512-gHnINm9ffFqz+G19cQUqRe3lsTAQO3Tbdj7r7Bx1ktZvC5X6iXd/nfo1DRTj9magb52aGRiuwB3yvD1lkW68xQ==` |
| `pi-acp@0.0.34` | `sha512-MrCp37UbpUzkTkzTIMJQf1RYrT+kr4fgGDGFoLmBN26UupuCZp0XxVIY+7XYsMo3yDnzDeZUJ0jPyM3Si6Bkkg==` |
| `@earendil-works/pi-coding-agent@1.1.0` | `sha512-SeEi/4hdcHNgA9UWlefZl7ZZpm3dzi2OoxNjDHsBJ9o298LNOtbL4DGKgitlEj6uCTccvtw6f2hlCkTPVJ2RXg==` |

Copilot's small npm launcher delegates to an optional native platform package; verifying only the launcher misses the executable. Review and pin every supported platform package separately. Retain Node 22+ for the common installer; final probes used Node 24.21.0.

**NixOS gate:** the generic Copilot 1.0.114 native executable exits 127 through NixOS stub-ld. A direct invocation through the installed glibc loader plus GCC library directory produced a valid handshake, but affected Copilot's self-executable metadata/version checks. That workaround is evidence collection only. Production support on NixOS requires a pinned host-compatible package/wrapper with correct self-exec and login behavior, then a complete rerun. Existing host Copilot 1.0.91 is not silently accepted as 1.0.114.

## 2. Live capabilities and limits of verification

Raw requests, responses, argv, allowlisted environment, probe source and package pins are preserved in `docs/audits/copilot-pi-acp-initialize.json`. The final probe used isolated HOME/XDG/provider directories and no inherited provider tokens or Heimdall credentials.

The initialize request used ACP protocolVersion 1 and the bridge's existing client capabilities: filesystem read/write delegation false and terminal delegation false.

| Capability | Copilot 1.0.114 | Pi adapter 0.0.34 + Pi 1.1.0 |
| --- | --- | --- |
| Protocol and reported identity | v1; Copilot 1.0.114 | v1; pi-acp 0.0.34; Pi version checked separately |
| `loadSession` | true | true |
| Prompt content | image=true, audio=false, embeddedContext=true | image=true, audio=false; embeddedContext=false by default, true with the protected environment toggle |
| MCP advertisement | http=true, sse=true | http=false, sse=false |
| Session capabilities | list, close | list, delete |
| Auth method | `copilot-login`, terminal login metadata | `pi_terminal_login`, terminal setup |
| Steering | No `_meta.steering.supported`; `_session/steering` returned -32601 | Same |
| Prompt queueing | No advertisement | No advertisement; packaged adapter has its own turn queue, which is not the Claude capability |
| Clean-profile `session/new` | -32000 Authentication required | -32000 Authentication required with Pi authMethods |

Keep the bridge inbox as the queue owner and send one `session/prompt` at a time for these providers. Without negotiated steering, priority messages wait for the current turn; do not reinterpret them as a second concurrent prompt or assume cancellation/resubmission preserves exactly-once delivery.

**Permissions and tool-call updates are not initialize capability flags.** Initialize alone cannot prove either. Copilot's official ACP example handles `session/request_permission` and streaming updates. The installed Pi adapter source maps tool execution to `tool_call`/`tool_call_update` and text to `agent_message_chunk`; it also emits extension UI requests through permissions. Actual authenticated tool runs, denial/cancellation, config/model selection and a successful `session/load` were not exercised. Their acceptance checks are explicit below. An additional Copilot local-BYOK config-only attempt timed out in `session/new`; it establishes no successful BYOK session.

## 3. Authentication, profiles and models

**Copilot:** keep provider `copilot` and existing/default/custom profile IDs. Inherit the selected profile's environment through `profile_child_env`. Use `COPILOT_HOME` for account/config/session isolation via existing environment rows; do not add a general HOME override. A profile can use interactive `copilot login` or a sensitive `COPILOT_GITHUB_TOKEN` row. GitHub documents token precedence as `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, then `GITHUB_TOKEN`, with stored credentials and GitHub CLI fallback also relevant. Review inherited credentials to ensure the intended account wins. OAuth/keychain account isolation must be tested rather than inferred from separate directories. See [GitHub authentication](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli) and [configuration directory documentation](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference).

BYOK is a distinct profile configuration using the CLI's `COPILOT_PROVIDER_*` variables or provider-config file. Preserve it as opaque, redacted profile environment; do not put API keys in the Hub catalog. The [CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference) and the pinned binary's `help providers-env` describe this path. Keep GitHub-hosted and BYOK model identities distinct and test each before claiming support.

**Pi:** keep provider `pi`; Pi's internal model provider such as `anthropic` or `openai-codex` is part of the model ID, not a new Heimdall provider/profile. Credentials remain in Pi's normal API-key/OAuth setup, with per-profile `PI_CODING_AGENT_DIR` and sensitive provider environment rows. Login runs in the same profile environment via Pi's interactive `/login` flow or adapter `--terminal-login`. The bridge forces the resolved profile binary into `PI_ACP_PI_COMMAND`; a user environment row cannot substitute a different executable after validation.

Resolve models against both the selected profile's known/custom model set and the session's advertised model options. Prefer `configOptions[category=model]` plus `session/set_config_option`, using the actual returned configId and verifying the response selected the exact requested ID. Pi maps models as `provider/model`. Preserve all slashes after the provider separator. Copilot's authenticated session config shape still needs recording; explicitly support a different advertised mechanism only if verified. Never silently fall back to a default model.

Runtime availability is shared per provider installation, while authentication, models and launch checks belong to the selected profile. The current canonical-profile readiness check must not certify custom-profile authentication. Preserve provider-wide transport selection. (Superseded by R3: transport is chosen per profile; see docs/specs/acp-runtime-transport.md.)

On -32000 auth-required startup, show provider-specific instructions and the selected profile context. Do not execute arbitrary terminal commands received in agent metadata; choose the trusted descriptor's login recipe. No automatic login UI is added by this plan.

## 4. Permissions, bootstrap and Pi adapter gaps

- **Copilot permissions:** start without global allow-all flags for `ask`; route actual ACP requests through the existing once-only relay. Record native session modes/options before mapping `yolo` or `ask`: do not assume a mode called default or autopilot is a permission mode. A possible implementation is bridge-owned ask/yolo policy over emitted requests, with yolo choosing only a unique `allow_once`; it must be proven against saved CLI permissions and enterprise policy first. Keep persistent `*_always` choices unavailable and cancellation fail-closed.
- **Pi tool permissions:** the existing catalog migration `082_pi_provider.sql` explicitly says Pi never asks per tool; `--approve` trusts project-local files and is not per-tool approval. The adapter does not introduce a universal pre-tool gate. Initial Pi ACP should support only the explicitly selected unrestricted/yolo policy and reject `ask` with a typed unsupported-policy error. Supporting ask requires an enforced Pi pre-tool approval extension or equivalent adapter work, with denial proven to prevent side effects. Reasoning mode must never stand in for that gate.
- **Pi extension choices:** in `pi-acp@0.0.34` (`src/acp/session.ts`), extension selects can emit several options all marked `allow_once`. Our binary permission resolver deliberately cancels duplicate kinds. A choice is not an allow/deny decision. Keep fail-closed behavior until a separately typed, exact-option UI/relay is implemented; confirm yes/no callbacks independently. Never auto-select the first option.
- **Pi persistence:** packaged `src/acp/paths.ts` fixes the map at `~/.pi/pi-acp/session-map.json`; `PI_CODING_AGENT_DIR` does not move it. `session-store.ts` performs unlocked read/modify/direct-write operations. Parallel adapters can lose entries or read a partial file. Require an upstream fix or a maintained, reviewed adapter patch for a stable per-instance state path, private permissions and atomic writes (or correctly locked shared writes). Do not change HOME to disguise the problem. The patch's exact version and SRI must be established and re-probed; do not invent a future upstream release pin.
- **Pi argv/trust:** the pinned adapter spawns only `--mode rpc --no-themes` and optional `--session`; it does not forward our profile launch arguments. `PI_ACP_PI_COMMAND` is a command path, not a shell command string. Add a reviewed argv-forwarding facility/launcher for validated profile arguments and explicit project trust. Test `.agents/skills` loading; do not append a space-separated shell fragment to the command variable. Keep model and permission selection under the bridge policy.
- **Bootstrap:** choose the catalog bootstrap filename rather than hard-coded `CLAUDE.md`; Copilot/Pi use `AGENTS.md`. Preserve embedded-resource bytes and the ACP communication instructions. Pi's resource translator includes embedded text, but actual model consumption is still an end-to-end check.
- **MCP/tools:** retain no fs/terminal delegation in initialize. Pi currently stores MCP declarations without wiring them into its RPC child; do not present ACP-provided MCP servers as operational. Native Pi extensions may configure their own tools separately. Tool updates, paths, edits, terminal metadata and usage must pass through the existing bounded event normalizer without provider hooks duplicating chat/activity.

The adapter-specific findings above come from the installed 0.0.34 bundle, whose source boundaries name [agent.ts](https://github.com/svkozak/pi-acp/blob/v0.0.34/src/acp/agent.ts), [session.ts](https://github.com/svkozak/pi-acp/blob/v0.0.34/src/acp/session.ts), [paths.ts](https://github.com/svkozak/pi-acp/blob/v0.0.34/src/acp/paths.ts), [session-store.ts](https://github.com/svkozak/pi-acp/blob/v0.0.34/src/acp/session-store.ts) and [RPC process.ts](https://github.com/svkozak/pi-acp/blob/v0.0.34/src/pi-rpc/process.ts).

## 5. Claude-specific code to generalize

Paths below are relative to the task worktree `/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/task_18e97c6373fb3428`.

| File / starting line | Required change |
| --- | --- |
| `src/contracts/runtime_transport.odin:6,50` | Recipe struct and validator currently require Claude command/package/protocol env. Add closed, typed native/adapter descriptors and pin validation; preserve unknown-recipe rejection and mirror changes in Hub/UI serializers. |
| `src/bridge/acp_adapter.odin:14,44,58,67,220,275,331` | Claude constants, allowlist, root/bin, manifest/lock verification, executable probe env, initialize and install must use provider descriptors and version tuples. Preserve safe diagnostic redaction. |
| `src/bridge/acp_runtime.odin:85,150,240,283,467,505,544` | Provider/version checkpoint, auth guidance, bootstrap file, capabilities, resolved CLI environment, spawn argv and launch policy. Separate permission policy from agent reasoning/session mode. |
| `src/bridge/acp_config.odin:8,32` | Keep Claude mapping in its descriptor; use advertised model/config IDs and provider-specific semantics. Retain bootstrap communication rewriting. |
| `src/bridge/acp_events.odin:265` | Current mode/config updates enforce Claude permission-mode equality. Validate only categories bound by the selected descriptor; Pi thinking updates must not trigger permission errors. |
| `src/bridge/acp_reconcile.odin:208,237`; `src/bridge/acp_state.odin:15` | Restore currently rejects any provider/version other than Claude/0.108.0. Persist descriptor identity, package/CLI versions, selected profile and capability/policy state; reject cross-profile/version substitution. |
| `src/bridge/acp_permission.odin:38,55,94` | Reuse binary once-only logic; add explicit unsupported-policy/choice handling where needed. Keep timeout, cancellation, checkpoint and stale-session rules. |
| `src/bridge/acp_inbox.odin:100`; `acp_chat.odin`; `acp_events.odin:252` | Reuse serialized prompt fallback and normalized tools/chat/activity; regression-test no steering and replay deduplication. |
| `src/bridge/provider_catalog_cache.odin:432`; `provider_profiles.odin:303,374` | Validate new descriptors, retain profile environment secrecy and driver-specific binary meaning; existing generic env rows suffice for provider config directories. |
| `src/hub/service/provider/runtime_transport.odin:38,59`; `src/hub/transport/http/provider_extension_handlers.odin:81,109` | Native runtime readiness, install command identity/version and profile-specific launch checks; canonical readiness alone is not account validation. |
| `src/bridge/bootstrap_service.odin:143,885`; `src/ui/components/providers/providerRuntime.ts:54`; `ProviderRuntimeControl.tsx:129` | Catalog bootstrap filename and clear native-runtime versus adapter status/auth errors. Preserve interactive debug IDs and existing transport controls. |
| `docs/specs/acp-runtime-transport.md`; new SQLite migration after current origin/main maximum | Document provider matrix and policy gates; add Copilot/Pi ACP recipes/transports and canonical catalog hash updates. Never edit or renumber released migrations. |

The descriptor selects fixed installation/launch behavior; it is not a general shell recipe interpreter. Keep existing Claude 0.108.0 behavior, dispatcher activity ownership, pipe receipts, epoch fencing, vault admission and durable chat outbox invariants.

## 6. Verification strategy

For implementation, use recorded real initialize responses as fixtures, plus focused bridge tests for each descriptor and a mandatory Claude regression. Exercise wrong package/version/SRI, unsupported platform, install timeout, interrupted staging, concurrent install and active-runtime promotion refusal. Verify `HEIMDALL_*` stripping during probes and protected binary/environment precedence at launch.

Test profile A/B account/config isolation, explicit model availability and selection, absent/changed config categories, revoked auth and sanitized provider-specific blockers. Test bootstrapping from each provider's catalog file with a unique marker visible to the model. Test no-steering inbox ordering, priority input during a turn, cancellation and no duplicate delivery.

Authenticated integration must record one read, edit and command tool, partial/final updates and paths, allow/deny/timeout/cancel, reasoning changes, and persistent permission refusal. For Pi, prove that `ask` fails before spawning or that a newly implemented gate actually blocks tool side effects. Exercise multiple-choice extension requests safely.

Recovery must cover Bridge reconnect to a surviving pipe, dead-child restart plus `session/load`, replayed history without duplicated chat/activity, frozen profile/version/policy matching, missing/corrupt provider session stores, and two Pi processes persisting simultaneously. A loadSession advertisement is not a successful resume test.

Run affected checks through `ham-ctl shell run` in each task worktree, with the repository Nix toolchain. Representative commands:

```bash
nix develop --command bash scripts/dev-odin.sh test src/bridge -define:ODIN_TEST_THREADS=1
nix develop --command bash scripts/dev-odin.sh test src/contracts
nix develop --command bash scripts/dev-odin.sh test src/hub/service/provider
nix develop --command bash scripts/dev-odin.sh test src/hub/repository/sqlite
nix develop --command bash scripts/dev-odin.sh test src/hub/transport/http
npm run typecheck
node --import tsx --test tests/ui_provider_runtime_test.ts tests/ui_provider_profiles_test.ts
nix build .#ham-bridge .#ham-pty-host
```

Choose focused suites according to touched packages, verify nonzero test counts, and use the documented private tmpfs plus DAC-capability drop for fsync-heavy serial fixtures on this bridge. Both listed UI test files exist in the inspected checkout; recheck them when implementing. Use named isolated local Hub/Bridge instances for live UI and recovery checks; do not restart the installed services. Validate Linux/macOS/Windows launch wrappers and the intended CPU architectures before advertising them as supported.

### Checks performed for this plan

- Exact npm metadata queries for Copilot 1.0.114/platform package, pi-acp 0.0.34 and Pi CLI 1.1.0; initial private install of `pi-acp@0.0.34 @github/copilot@1.0.114` succeeded.
- `node .acp-plan-research/probe.mjs`: final run exited 0 in managed session `sh_fd3e43b97fee2087bfba0d57a9d1880a`; three actual initialize results, three expected auth errors, three -32601 steering errors and Pi embedded-context toggle verified.
- Version probes: installed Pi 1.1.0; live Copilot agentInfo 1.0.114; Node 24.21.0.
- `node .acp-plan-research/config-probe.mjs`: local-BYOK session/new timed out; no authenticated config/tool claim.
- Exploratory Pi 1.5.2 npm install failed with registry EIDLETIMEOUT after 312 seconds. Final evidence uses the complete, installed Pi 1.1.0 package. Generic Copilot Nix loader failure and initial probe close-event bug were investigated and bounded.
- Production builds and existing test suites are deliberately skipped for this documentation/evidence-only task. The final handoff records whitespace, evidence-consistency, reference and clean-tree checks.

## 7. Proposed tasks and acceptance

These are proposals for review, not newly created tickets. Scope lock remains in force.

| Order / task goal | Acceptance |
| --- | --- |
| 1. Generalize ACP descriptors, installation and recovery identity | Closed Claude/Copilot/Pi descriptor validation; reviewed package/platform pins and locks; native/adapter readiness; staged integrity-checked installs; profile-aware launch checks; provider/version/profile-bound journal and restore; Claude regressions pass. Add only new migrations after current main. |
| 2. Add Copilot native ACP launch and policy/config handling | Pin 1.0.114; exact resolved argv and auto-update disabled; successful authenticated prompt/bootstrap and model selection; ask/yolo semantics proved without persistent grants; tools/chat/activity normalized; reconnect/load works; auth failure guidance matches profile; host-compatible Nix launch or explicit unsupported-platform status. |
| 3. Resolve Pi adapter fleet prerequisites | Review an upstream fix or narrowly maintained patch for stable isolated state maps, atomic writes, argv forwarding/project trust and extension-choice behavior. Establish exact resulting version/SRI and rerun initialize/config/concurrency checks. No claim that unmodified 0.0.34 is fleet-ready. |
| 4. Add Pi ACP launch, profiles and supported policy | Adapter pin from task 3 plus Pi CLI1.1.0 (or a separately verified revised pin); protected executable/context env; AGENTS.md and skills consumed; exact provider/model and thought_level config; concurrent session persistence and load; tools/chat mapped; yolo explicit and ask rejected until an enforced gate is implemented; selection UI cannot be mistaken for binary permission approval. |
| 5. Validate and expose supported runtimes | Cross-provider/Claude regression matrix, private-profile authentication and negative cases, isolated Hub/Bridge UI/recovery tests and platform checks pass; catalog/status/docs reflect capabilities and limits; user review before release. No release is performed by this planning task. |

## 8. Risks and unresolved gates

The largest risks are Pi's unlocked shared session map, lack of universal tool approval, and missing profile argv forwarding. Fixing these may require a maintained adapter change; the future pin cannot be declared before that work exists. Pi `ask` support is a separate implementation requirement if desired.

Copilot's native npm distribution differs from the older installed JS package and needs a supported NixOS packaging path. OAuth/keychain behavior, enterprise policy and subscription/model availability can differ by profile. The clean probes did not authenticate; config, tool and actual resume behavior must pass the proposed acceptance gates.

Both agents lack the Claude steering extension at these pins. Document that priority messages cannot interrupt an executing turn through steering. Neither an internal Pi queue nor a top-level initialize capability should override the bridge's durable delivery rules.

Adapter dependency drift, platform-specific binaries, auto-update behavior, Pi extensions/project trust, and bootstrap duplication are release risks addressed by frozen installs, explicit policy and live regression checks. Installation readiness must stay independent from account readiness, and no missing capability may trigger an unannounced PTY/provider/model fallback.
