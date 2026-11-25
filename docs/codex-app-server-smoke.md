# Codex app-server authenticated smoke — 2026-11-22

The Linux smoke verified native startup, prompts, incremental chat notifications, exact model selection, yolo execution and interruption. **Do not use this result as rollout signoff:** real ask-mode approval cards and Bridge restart/resume failed. Four defects are tracked below. T4 permits explicit gaps and tracked defects; this delivery records them without changing production behavior.

## Environment and identities

- Host execution bridge: `brg_18e0e5e547267b4e` (dawnstar).
- Tested source: `f56f13e106949d67e1e139d100600860cf3d3f44`, including T1–T3.
- Workdir: `/home/tanmay/heimdall-agent-manager/.heimdall/worktrees/t4_smoke`.
- Built Hub, Bridge, CLI, dev proxy and PTY host from that checkout using Nix; application version `0.5.71`.
- System Codex: `codex-cli 0.162.0`; `codex login status`: `Logged in using ChatGPT`.
- Named isolated stack: `t4-codex`; Hub `18881`, proxy `18880`, UI origin `15873` (no browser server), mock OIDC `18890`, Bridge `49881`, endpoint `49882`.
- Isolated bridge: `brg_18ea47555b25c045`. Only Codex authentication was copied into its isolated provider HOME; the installed services and real provider home were untouched.
- Ask instance: `inst_18ea47755ff55083`; conversation `chat_18ea47755ff55bc3`.
- Yolo instance: `inst_18ea47755ee37084`; conversation `chat_18ea47755ee37d82`.

[Machine-readable evidence](evidence/codex-app-server-smoke-2026-11-22.json) contains selected transcripts, notification timestamps, native model/sandbox/abort records and before/after journals. It contains no login material, agent tokens or vault keys. Raw isolated state remains outside git. The reproduction helper is [codex_app_server_smoke.mjs](../tests/e2e/codex_app_server_smoke.mjs).

## Scenario results

| Scenario | Result | Direct evidence and limits |
| --- | --- | --- |
| System detection and readiness | Pass after Re-check | Initial catalog default was `pty`, available transports `[pty, acp]`. ACP enablement first returned `acp_unavailable` until explicit `POST .../providers/codex/acp-adapter {"action":"install"}` performed the initialize probe. No managed adapter install or login flow was substituted. |
| Native start | Partial | Both instances reached `running` on ACP. Ask startup CLI failed to reach its endpoint; the Bridge's automatic ready transition does not establish CLI usability. First concurrent yolo launch failed; a later stop/start succeeded. |
| Prompt and final reply | Pass | Ask prompt “Remember marker ACPSMOKE27. Reply with the marker only.” produced `ACPSMOKE27`, message `msg_b2d8d97ce84b2ea5`, complete revision 2. |
| Streamed reply | Pass at API level | Yolo rain reply `msg_d234342994d1feaa`: pending revisions 2–9 arrived via user WebSocket between `05:44:46.614Z` and `05:44:49.480Z`; complete revision 12 at `05:44:49.759Z`. Final decrypted body begins “RESUME73 / Rain softens the edges of a busy afternoon”. Notifications specify `fetch_required=true`; intermediate bodies were not separately fetched. No browser rendering claim. |
| Model selection | Pass | Reconfiguration `reconfig_18ea47b3dfc1adc2` changed `gpt-6.1-sol` to `gpt-6-luna`. Hub instance, selected-model journal and native `turn_context.model` agree. Native context also proves ask=`workspace-write` / `on-request`, yolo=`danger-full-access`. |
| Ask approve once | Gap: request invisible | Native `item/commandExecution/requestApproval` and stable `acpperm_8f542137ba7e3c9b1b5a536d0315a2af199a6720` were journaled, but Hub blockers stayed revision 0 / empty. No decision could be sent through a card. Marker `t4-allow` was never created. |
| Ask deny once | Gap: request invisible | Second independently requested escalation for `t4-deny` had the same missing-card behavior. No deny decision was exercised. Marker absence is not counted as a successful denial. |
| Yolo automatic behavior | Pass for execution; branch coverage limited | Native command `printf T4_YOLO > <isolated-home>/t4-yolo` executed; file content `T4_YOLO`; no Hub blocker. Yolo native policy disables these approval requests, so this does not exercise the Bridge's auto-accept branch for a live inbound request. Existing driver fixtures cover that branch. |
| Interrupt awaiting approval | Pass | Encrypted agent-stream Ctrl-C cancelled native turn `01a201c5-d573-74f3-a5d6-562dd3fb4811`; native `turn_aborted.reason=interrupted`; durable assistant `msg_09a93ea117dd0db5` finalized with `stop_reason=cancelled`. |
| Interrupt active command | Pass | Yolo `sleep 60` turn `01a201c9-e9af-77b0-b38f-b8e48c6a2c0b` aborted after 23.020 seconds with native reason `interrupted`; journal returned to ready. Ctrl-C used a current Bridge boot ID and PTY-v2 encryption. |
| Graceful Bridge restart with resume | Failed | PID `99626 -> 112770`. Instance became stopped. Saved thread remained `01a201c8-6cf8-7152-97f5-ffd4afb4bb8d`, stdout sequence 120 unchanged. A later prompt auto-started a new epoch/thread instead of resuming. |
| Forced Bridge crash with resume | Failed | After a new thread replied `CRASH84`, only isolated Bridge PID `112770` was SIGKILLed; restart PID `115819`. Instance again stopped; saved thread `01a201cb-8dfc-79a0-a7b2-a71633b5efee`, sequence 39 unchanged. No subsequent prompt was used to conceal the failed recovery. |

For graceful restart, the pre-restart epoch was `launch_18ea47b3dfc324ac`. The later auto-start created `launch_18ea47e3b9611971`, proving replacement. A retained session ID in a journal is not evidence of a running resumed session.

## Tracked defects

| Issue | Finding | Next investigation |
| --- | --- | --- |
| `iss_18ea47c53c7b766f` | Native ask approval pending without a Hub card; activity shown idle | Trace `acp_permission_start`, worker lifecycle and blocker publication with real native requests. Approve and deny remain mandatory live follow-ups. |
| `iss_18ea47cace8d25c4` | Concurrent starts: `acp_adapter_unavailable`, failed launch remains Hub `starting` | Inspect advisory-lock admission and launch-failure projection. Shared install/profile lock contention is a candidate, not a confirmed root cause. |
| `iss_18ea47dac8f2cff8` | Ask sandbox cannot reach local CLI endpoint | Startup command returned exit 1: “local Bridge endpoint is not reachable”; identical yolo startup succeeded. Sandbox connectivity is inferred from native policy, not conclusively isolated. Preserve ask security while making the required RPC path reachable. |
| `iss_18ea47fd743242ef` | Graceful and crash restart do not restore a running native thread | Trace actual Hub intent, pipe inventory, token records and reconciliation. Re-run continuity with unchanged epoch/thread and a post-recovery marker reply. |

No production fixes were made: the task explicitly allows defects to be tracked. The helper and this evidence do not alter Claude, Copilot, Kiro, provider catalogs, migrations or installed services.

## Commands and validation

Commands below ran in the task Workdir through the managed `ham-ctl shell`. Long operations used background runs and their completion logs were read.

```bash
nix build .#ham-hub .#ham-bridge .#ham-ctl .#ham-dev-proxy .#ham-pty-host --no-link --print-out-paths
npm ci --ignore-scripts
codex --version
codex login status
codex app-server generate-json-schema --out "$PWD/.heimdall/t4-codex-schema"

nix develop --command scripts/local-hub.sh start --name t4-codex --no-ui --no-plan-limits --bin-dir "$PWD/.heimdall/t4-bin"
nix develop --command scripts/local-bridge.sh start --name t4-codex --hub t4-codex --auto-enroll --providers codex --port 49881 --local-endpoint-port 49882 --bin-dir "$PWD/.heimdall/t4-bin"

node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/codex_app_server_smoke.mjs setup
CODEX_SMOKE_INSTANCE=ask node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/codex_app_server_smoke.mjs prompt 'Remember marker ACPSMOKE27. Reply with the marker only.'
node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/codex_app_server_smoke.mjs reconfigure gpt-6-luna
node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/codex_app_server_smoke.mjs interrupt
node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/codex_app_server_smoke.mjs journal

nix develop --command bash scripts/dev-odin.sh test src/bridge -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=codex_driver_handshake_bootstrap_and_ask_yolo_policy,codex_driver_streams_items_and_notification_owned_completion,codex_driver_interrupt_steer_and_terminal_statuses,codex_driver_approval_schemas_relay_yolo_replay_and_cancel,codex_driver_resume_retries_unarchive_and_never_creates_new_thread
node --check tests/e2e/codex_app_server_smoke.mjs
```

- Nix builds, dependency installation, schema generation and helper syntax check: exit 0.
- Focused Bridge fixtures: **5/5 passed**, exit 0, memory tracking enabled with no warnings. These are fixture checks, not replacements for the failed authenticated scenarios.
- Evidence extraction: **7/7 assertions** validated marker reply, yolo marker content, absence of allow/deny markers, incremental revisions, native selected model, native interrupt and final stopped state. Checking that a failure was observed is not an E2E pass.
- Full Bridge/Hub/UI suites were not repeated: production code is unchanged, T3 already reported broad checks, and this task targets authenticated integration. No Windows/macOS, browser or physical-disk durability claim.
- Initial Hub start outside Nix failed because `nats-server` was absent from PATH; starting under `nix develop` succeeded.
- An initial interrupt attempt incorrectly used content-envelope encryption with REST `/input` and returned 400. It was replaced by the UI's actual encrypted agent WebSocket input path; only that latter path is counted as verified.
- The helper's `setup` deliberately creates instances back-to-back to reproduce the admission issue. It does not assert that “setup exit 0” proves readiness. Inspect `status` and `journal` before prompting.
- The helper is a manual fixture, not part of the unattended test suite. It uses the named isolated stack, its seed approver, and the existing vault modules. It writes decrypted fixture evidence to a private `.heimdall/t4-evidence` directory and never exports the keyring.

## Reproduction and cleanup

Build outputs were linked into `.heimdall/t4-bin`. The initial named Hub creation used ports `--hub-port 18881 --proxy-port 18880 --ui-port 15873 --oidc-port 18890`; later starts reused those recorded ports. Run `npm ci --ignore-scripts` before using the vault helper. Keep the same fixture name/ports; the helper is intentionally specific to `t4-codex`.

For approval prompts, use the exact isolated-home commands in the JSON transcripts with `sandbox_permissions=require_escalated`, then read `status` and `journal`. If a card appears after a fix, `resolve <blocker-id> allow|deny` sends a once-only decision; check actual file presence/content afterward. Do not turn absence of a card or file into a denial result.

For recovery, save `journal`, restart only the isolated Bridge, check `status` before any prompt, then compare session/epoch and require a real response on the recovered thread. Do not manually start the instance before judging automatic recovery.

```bash
nix develop --command scripts/local-bridge.sh stop --name t4-codex
nix develop --command scripts/local-hub.sh stop --name t4-codex
```

Cleanup completed with both stop commands (exit 0): isolated Bridge, Hub, dev proxy, mock OIDC and private NATS stopped. These commands retain the isolated state for investigation; do not purge copied authentication as part of report cleanup. No installed Hub/Bridge restart is required.

## Rollout notes

**Hold production signoff.** Keep Codex ACP opt-in and PTY as the default while the four issues are investigated. Re-run live approve/deny and automatic restart/resume after fixes; passing fake-wire tests alone is insufficient.

Hub and Bridge must ship together: older Bridges reject provider catalogs containing unknown ACP rows. Deploy matching builds before enabling the per-Bridge Codex transport, retain the pinned descriptor/schema contract, run System **Re-check** with the selected profile's `CODEX_HOME`, and verify its ChatGPT login locally. Do not modify released migrations, silently switch models, grant persistent approval choices or change other providers. Returning the provider override to PTY affects subsequent launches; explicitly stop affected ACP instances before relaunching.

The [official OpenAI app-server documentation](https://developers.openai.com/codex/app-server/) describes thread/turn lifecycle and streamed events. For this smoke, installed `0.162.0` generated schemas and native traces are the version-specific evidence.
