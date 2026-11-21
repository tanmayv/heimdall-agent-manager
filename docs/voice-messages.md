# Voice messages

How a user's voice message reaches an agent and how the agent answers it with text plus a voice
note. Ninjy carries the audio as artifacts and attachments. It ships **no speech code and no
models**. Speech-to-text (STT) and text-to-speech (TTS) come from a speech service that the user
runs. The service must be OpenAI-compatible, and agents reach it through the Hub relay.

Requirements: REQ-VOICE-2 (user-provided speech service contract) and REQ-VOICE-6 (agent guidance).

## Flow

```text
 user speaks                     Ninjy                                    agent (any bridge)
 ───────────                     ─────                                    ──────────────────
 Ninjy chat (mic, webm/opus) ─┐
 Telegram voice (ogg/opus)  ──┼─> artifact kind=voice|audio, mime ───> chat read / channel read
 WhatsApp voice (ogg/opus)  ──┘   attached to the message                     │
                                                                              ▼
                                                     ham-ctl artifact download <art> --dir <d>
                                                                              │
                                    Hub relay  <── POST /proxy/<sid>/v1/audio/transcriptions
                                  (shell server                               │ {"text": …}
                                   session on the                             ▼
                                   speech host)                       agent acts on the text
                                                                              │
                                    Hub relay  <── POST /proxy/<sid>/v1/audio/speech (opus)
                                                                              │ reply.ogg
                                                                              ▼
                       ham-ctl artifact create --kind audio --content-type audio/ogg --file reply.ogg
                       ham-ctl chat send --to user --body "<text>" --artifact <art>      (Ninjy chat)
                       ham-ctl channel send --text "<text>"; channel send --artifact <art> (bots)
```

1. **Inbound.** The audio becomes an artifact attached to the message. Telegram and WhatsApp voice
   notes become `kind=voice`. Other audio becomes `kind=audio` with its original mime (`channel
   read`, `src/ctl/channel_media.odin`). Message rows list
   `artifacts: [{artifact_id, kind, mime, available}]`, so a terminal agent sees the kind in
   `chat read` JSON. An ACP agent sees `artifact_refs: [art_x (voice, audio/ogg)]` in its prompt.
2. **Transcribe.** The agent downloads the artifact and posts it to the speech service's
   `/v1/audio/transcriptions` through the relay.
3. **Act.** The agent treats the transcript as the user's message.
4. **Reply.** The agent synthesizes the **same text** it sends as an OGG/Opus voice note, uploads
   it as `kind=audio`, `content_type=audio/ogg`, and sends the text with the voice note attached.
   - Ninjy chat: one message, `chat send --body <text> --artifact <art>`.
   - Telegram and WhatsApp: `channel send --text <text>`, then `channel send --artifact <art>`.
     WhatsApp voice notes cannot carry a caption, so the text goes in its own message. An
     `audio/ogg` artifact goes out as a native voice note (Telegram `sendVoice`, WhatsApp audio
     with `voice: true`).

## Speech service contract

Any server that implements this subset of the OpenAI audio API works. Examples are
[speaches](https://github.com/speaches-ai/speaches), a hosted OpenAI-compatible endpoint, or a
custom wrapper.

| Endpoint | Request | Response |
|---|---|---|
| `GET /health` | – | `200` when the service is up |
| `POST /v1/audio/transcriptions` | `multipart/form-data`: `file` (audio), `model` (e.g. `whisper-1`), optional `language` | `200 {"text": "…"}` |
| `POST /v1/audio/speech` | JSON `{"model": "tts-1", "voice": "<voice>", "input": "<text>", "response_format": "opus"}` | `200`, an Ogg container with an Opus stream |
| `GET /v1/audio/voices` (optional) | – | voice list (speaches extension) |

Formats:

- **STT input:** anything ffmpeg decodes. In practice this means `audio/ogg` (opus) from
  Telegram/WhatsApp, `audio/webm` (opus) from browser recordings, and mp3/wav/m4a. The file
  extension does not matter. `artifact download` may name the file `*.bin`, and that is fine.
- **TTS output for replies:** `response_format: "opus"`, which is Ogg/Opus, 48 kHz mono.
  speaches labels it `Content-Type: audio/opus`. **Upload it as `audio/ogg`**, the type chat apps
  treat as a voice note.
- `voice` is **required**. Without it, speaches answers `422 Field required`. With an unknown
  voice, it starts a `200` and then drops the stream (curl exit 18). riverwood's default is
  `af_heart`.

Limits:

- **Relay uploads ≤ 25 MB** (OpenAI's limit too). Send compressed audio, not WAV. A 60 MB upload
  through the relay closed the bridge→Hub WebSocket and the request hung. A voice note is usually
  well under 1 MB (ogg/opus is about 16–32 kB/s).
- Two `opus` responses for the same text differ in bytes 15–18 (the random Ogg stream serial).
  To compare outputs, compare decoded PCM, or request `wav`/`flac`.

## Relay access

Machines are not assumed to be connected to each other. The only path an agent may rely on is the
**Hub relay**, an `ham-ctl` *server* session on the speech host that declares the service port.
Any bridge of the same owner can then reach the service at
`<local bridge>/proxy/<session_id>/…`. The service itself stays bound to `127.0.0.1`.

**Discovery.** Session ids change when the relay restarts, so look the id up by label and port
every time, in this order:

1. `ham-ctl shell list --bridge <speech-host-bridge> --status running`, filtered to
   `label == "speaches-relay"` and `server_port == 8770`. This is authoritative and lists the
   owner's sessions on every bridge.
2. `~/services/speech/relay.json` on the speech host: a cache written by `relay-up.sh`. Check it
   with `/proxy/<sid>/health` before trusting it.
3. No session (for example after a reboot of the speech host, which kills it): run
   `relay-up.sh`. It is idempotent and reuses a live session. Off the speech host it needs
   `--chain <chain_id>`.

**Calling through the local bridge.** An agent's own bridge endpoint is in
`HEIMDALL_BRIDGE_ENDPOINT`: either `unix:<path>` or `tcp:127.0.0.1:<port>`.

```bash
SID=$(ham-ctl shell list --bridge brg_18e8db5c741d67df --status running | python3 -c '
import json,sys
ss=[s for s in json.load(sys.stdin)["data"]["data"]["sessions"]
    if s.get("label")=="speaches-relay" and s.get("server_port")==8770]
print(ss[0]["session_id"] if ss else "")')
# unix socket endpoint:
curl -s --unix-socket "${HEIMDALL_BRIDGE_ENDPOINT#unix:}" "http://localhost/proxy/$SID/health"
# tcp endpoint (or the configured local_endpoint_port from `ham-ctl bridge list --scope configured`):
curl -s "http://${HEIMDALL_BRIDGE_ENDPOINT#tcp:}/proxy/$SID/health"

# STT and TTS (tcp form shown; with a unix endpoint add --unix-socket as above):
R="http://${HEIMDALL_BRIDGE_ENDPOINT#tcp:}/proxy/$SID"
curl -s "$R/v1/audio/transcriptions" -F file=@voice.ogg -F model=whisper-1          # {"text":…}
curl -s "$R/v1/audio/speech" -H 'Content-Type: application/json' \
  -d '{"model":"tts-1","voice":"af_heart","input":"Hello","response_format":"opus"}' -o reply.ogg
```

Measured on riverwood (same host, Hub round trip): `/health` takes about 0.13 s. STT of a 10 s
clip takes 1.1–1.3 s, against 0.8 s direct. A TTS sentence takes about 0.4 s. A 25 MB upload
takes 41 s, against 18.5 s direct.

## Agent guidance

Agents learn this procedure from a **global-scope memory** that the user approves. It is not
built into Ninjy. The Hub pins every agent proposal to the proposing agent
(`agent_action_memory_propose_handler`), so the user must remove that agent from the scope when
approving it (Settings → Memory). Alternatively, the user can create the memory directly with no
scope flags (`ham-ctl hub … memories create`). The memory gives the raw commands above and points to an optional helper script
on the speech host, `~/services/speech/voice-reply.sh`. The script is the user's tooling, not repo
code:

```bash
voice-reply.sh inbound <artifact-id>               # download + transcribe -> {"file","text"}
voice-reply.sh reply "<text>" --to user            # TTS + artifact create + chat send --artifact
voice-reply.sh reply "<text>" --channel            # TTS + channel send text, then the voice note
voice-reply.sh transcribe <file>                   # print the transcript
voice-reply.sh speak "<text>" <out.ogg>            # write an OGG/Opus voice note
voice-reply.sh relay                               # print /proxy/<session_id>
```

The script discovers the relay in the order above and refuses uploads over 25 MB. It defaults
the voice to `af_heart` (`SPEECH_VOICE` overrides it) and checks that the TTS reply is an Ogg
stream. Agents on other machines can copy it together with `relay-up.sh`, or use the raw
commands.

## Example setup: riverwood

riverwood's service is one working example. It is kept in `~/services/speech` on that host,
never in this repo. `~/services/speech/README.md` there is the operations guide.

| Item | Value |
|---|---|
| Server | speaches `0.9.0-rc.3-cuda-12.6.3`, pinned by digest, Podman quadlet `speaches.service` on `127.0.0.1:8770` with the GPU via CDI |
| STT | `deepdml/faster-whisper-large-v3-turbo-ct2` (CUDA float16), alias `whisper-1` |
| TTS | Kokoro `speaches-ai/Kokoro-82M-v1.0-ONNX`, aliases `tts-1`/`tts-1-hd`, default voice `af_heart` |
| Caps | container `--memory=12g --memory-swap=12g --cpus=4`; unit `MemoryMax=12G MemorySwapMax=0 CPUQuota=400%` |
| Restart | `Restart=on-failure`, at most 5 starts per 600 s, so a crash cannot loop forever |
| Boot | `HF_HUB_OFFLINE=1`; `speaches-warmup.service` loads the models with `POST /api/ps/<model>` (not `PRELOAD_MODELS`, which calls the HF API and fails offline) |
| Relay | `relay-up.sh` starts a server session with label `speaches-relay` and port `8770` on bridge `brg_18e8db5c741d67df`. Its process only follows the journal, so speaches restarts do not affect it. It does not survive a host reboot; run `relay-up.sh` again afterwards |

To set up a different host, run any OpenAI-compatible speech server bound to loopback. Then start
a server session for its port with a stable label, and give agents that label and port in the
memory.

## Not covered

- No STT or TTS runs inside Ninjy. The hub, bridge and UI never call a speech service.
- Streaming or real-time voice: messages are whole files.
- Automatic transcription of every voice message. An agent transcribes only when it handles the
  message.
