# Recording and playback waveform plan

Add real audio waveforms to the existing shared voice UI, following the [WhatsApp iPad reference](artifact://art_18ea239745cbf1a6). This document is the planning deliverable for task_18ea23910f81e5bd, requirements revision 1. User approval of this plan precedes one implementation ticket. Release and deployment require a later task.

## Source map and current behavior

Paths below are relative to /var/home/tanmay/heimdall-agent-manager.

| Exact path | Current responsibility and planned work |
| --- | --- |
| src/ui/components/chat/AudioPlayer.tsx | Shared HTML audio playback from already-decrypted blob URLs; replace visible straight seek slider with rounded real-peak bars, played color and circular marker. Keep play/pause, elapsed/duration, errors, duration hints and duration-less WebM handling. |
| src/ui/components/chat/useVoiceRecorder.ts | Owns the sole microphone stream, MediaRecorder, timer, session guards and preview URL. Add real amplitude analysis to this stream and integrate analysis teardown with existing releaseStream paths. |
| src/ui/components/chat/VoiceRecorderPanel.tsx | Shared composer recording/preview UI and useVoiceMessage upload glue. Show elapsed time at left with flowing rounded bars; preserve Cancel/Stop and preview Discard/Send semantics. |
| src/ui/components/workbench/AgentChatPane.tsx | Hosts shared panel with conversation debug prefix and existing send/disabled gates. Verify integration and responsive constraints; change only if needed. |
| src/ui/components/bots/BotChatPage.tsx | Hosts same panel with bot-chat debug prefix. Verify identical behavior and responsive layout. |
| src/ui/components/ArtifactAudioPreview.tsx | Existing vault-decrypted audio URL and transcript integration. Preserve decryption, transcript and object URL ownership. |
| src/ui/components/ArtifactAttachmentPreview.tsx | Routes message audio attachments to inline previews. Verify inherited shared-player change. |
| src/ui/components/ArtifactViewer.tsx | Hosts shared player for opened audio; verify inherited waveform and cleanup. |
| src/ui/utils/audioArtifact.ts | Existing MIME selection, duration formatting and recording limits: 10 minutes and 15 MiB. Preserve codec negotiation and guards. |
| tests/ui_voice_messages_test.ts | Existing fake-recorder, permission, lifecycle, player seek/duration and upload coverage; extend meaningful behavioral tests for waveforms. |
| src/ui/components/chat/AudioWaveform.tsx; src/ui/utils/audioWaveform.ts | Proposed new shared visual and bounded peak-analysis helpers, if useful. Final helper decomposition belongs to implementation worker. |

AudioPlayer currently never fetches remote artifacts. Analysis must consume the existing decrypted blob content/URL, never bypass authentication or introduce a remote waveform endpoint.

## Requirements and acceptance

| Requirement | Acceptance |
| --- | --- |
| REQ-WAVE-1 | Real decoded audio peaks drive compact rounded vertical playback bars next to play/pause, time below, theme-colored played portion and circular seek marker. Preview blobs and fetched/decrypted voice attachments both work. Existing transcript, duration, decryption and playback controls remain functional. |
| REQ-WAVE-2 | Recording displays microphone amplitude from the existing stream. Quiet versus loud fixtures produce correspondingly different measured values. Starting one recording calls getUserMedia once; no second microphone request or audio monitor output. |
| REQ-WAVE-3 | Both agent and bot composers use shared waveform visuals and existing tokens such as --color-accent, muted text and surface/border colors. Reference appearance is adapted to existing UI; send remains the existing preview/send action, not a new recording-time auto-send. |
| REQ-WAVE-4 | Touch tap/drag seeks with clamped endpoints, including pointer cancel and release outside the bar. Keyboard range supports arrows and Home/End. Expose labeled range min/max/current and human-readable elapsed/total value to assistive technology, with visible focus. Decorative bars are hidden from screen readers; avoid announcing each amplitude frame. Reduced motion removes flowing animation while retaining meaningful measured level/time. Controls remain usable at 320px width, iPad portrait/landscape and 200% zoom; target touch controls at least 44 CSS px. |
| REQ-WAVE-5 | Peak/history/cache/decoded-audio work has explicit numeric bounds and stale results cannot update replaced/unmounted players. Cancel animation frames, disconnect source/analyser, close owned AudioContext and release buffers on stop/cancel/error/unmount. Existing track stopping and URL revocation remain intact. Unsupported/oversize/failed decoding keeps HTML audio playable with accessible seeking fallback when duration is known; unknown duration disables seeking until known. Never synthesize/randomize amplitudes. |
| REQ-WAVE-6 | No autoplay or analysis-triggered playback. No automatic upload; only existing Send initiates upload. Existing permission denial/cancel, stop, duration/byte limit, discard, retry and navigation behavior survives. Record and playback codec negotiation remains browser-dependent. Report actual Safari/iPad verification and limitations explicitly. |

The reference shows the recording timer at left and amplitude strip to the right, with discard/stop/send controls below. The implementation should retain current product action semantics while adopting the waveform treatment.

## Resource lifecycle and bounded work

Use one analyser attached to the acquired recording stream, never connected to speakers. Construct/resume owned Web Audio resources within the recording user-action flow where possible; suspended or unsupported analysis must degrade to a truthful unavailable visual without blocking recording. Sample into reused typed arrays and fixed-size history, rather than accumulating one value forever. Stop rendering when hidden as appropriate and resume from current stream state without duplicating loops.

For playback, decode only bounded content on demand or when visible; avoid eagerly decoding every message. Reduce channel samples to fixed-count peak bins, then release AudioBuffer/ArrayBuffer references. Cache only compact peaks with explicit eviction; do not retain decrypted PCM indefinitely. Limit concurrent decode jobs and reject stale completions using the existing src/session identity style. Abort fetch/read work where possible; decodeAudioData may not be cancellable, so ignored completion must still release owned resources.

Suggested initial budgets for worker validation: one concurrent playback decode, at most 256 peak bins per clip, recording history at most 128 bins, visual updates at most 30 Hz, and compact-peak cache at most 32 entries with a byte ceiling. A compressed-byte cap alone does not bound decoded PCM: require a decoded-size/duration admission strategy before full decode, or fall back for files without safe metadata. Worker must document final numeric limits and evidence before acceptance; browser decoder internals cannot be promised a hard memory cap. Keep existing recording limits unchanged.

One idempotent teardown path must handle normal Stop, duration/byte auto-stop, Cancel during permission acquisition, late stream acquisition after Cancel, MediaRecorder construction/start/error, source replacement, conversation change and unmount. Recording analysis failure must not destroy an otherwise viable recording. Playback analysis owns neither the parent's blob URL nor the parent's decryption lifecycle.

## Safari and accessibility verification

Test supported Safari recording MIME chosen through existing MediaRecorder.isTypeSupported negotiation; do not force WebM/Opus. Exercise Safari-produced MP4/AAC where supported, browser WebM/Opus, fetched Ogg/Opus and a known-decodable WAV fixture. HTML playback support and Web Audio decode support must be checked independently: failed peak decode must not be treated as failed playback.

Check AudioContext availability/resume under real user gestures, permission prompt cancellation, background/foreground, interruption, repeated recording, duration metadata, iPad touch seeking and VoiceOver time/range announcement. Automated WebKit is useful evidence but is not an iPad microphone or VoiceOver check. If no physical Safari/iPad session is available, record it as unverified and provide exact manual steps; do not claim device compatibility from Chromium mocks.

## Implementation ticket and review assignments

After this plan is approved, create one implementation ticket covering REQ-WAVE-1..6 with this plan and the reference artifact as inputs.

- Implementation worker: agt_18dbb3d25b612dcd.
- Independent reviewer: agt_18dbb3d25c4e8afe.
- Final acceptance: user review through the task review gate.
- Release/deployment: subsequent separately scoped task after implementation approval.

The worker chooses the checks and must supply recording and playback screenshots for both chat surfaces, measured lifecycle/seek outcomes, final resource budgets and device limitations. The reviewer independently checks requirement coverage, real amplitude provenance, accessibility semantics, teardown/races, resource admission and preservation of vault/upload behavior. No implementation agents are started by this planning task.

## Verification and evidence expected from implementation

Run focused behavior tests (existing command: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_voice_messages_test.ts), npm run typecheck and npm run build. Run npm test when integration scope warrants it. Add any new suite to the test script if needed; worker owns final command selection and reports exact results.

Behavior evidence must include known peak fixtures and silence, seek endpoints/midpoint/touch/keyboard, decode rejection and oversized input fallback, stale decode after src change, cancellation before microphone resolution, all cleanup paths, repeated mount/unmount without growing contexts/RAF/cache, no extra microphone request, and no playback/upload side effect from analysis. Existing duration-less WebM, decrypt/transcript and send/discard tests must remain green.

## Planning confidence and limits

Planning confidence: 90%. The screenshot was inspected and source paths, shared integrations, recorder resource ownership, duration handling and existing tests were inspected directly. This confidence concerns feasibility and scope, not completed browser validation. No implementation, device tests, build, deployment, backend or speech/model changes form part of this planning deliverable.

