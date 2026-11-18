# Fake Telegram Bot API

Requires Node 20 or newer; no dependencies. Binds only to loopback.

```sh
node tools/fake_telegram/server.mjs --port 18099 --token TEST:FAKE --bot-username ninjy_test_bot
```

Set the isolated hub's Telegram API base to `http://127.0.0.1:18099`.
Do not use a real token. Bot endpoints live under `/botTEST:FAKE/`:
`getMe`, `getUpdates` and `sendMessage`. A wrong token returns 401.
Updates remain queued until acknowledged by a later `getUpdates` offset.
Empty polls wait up to the requested timeout (maximum 30 seconds).

Control endpoints:

- `POST /_control/inject`: JSON `{"chat_id":111,"from_id":222,"username":"alice","text":"hi","chat_type":"private"}`; returns `{"update_id":N}`. Omit text for an unsupported photo. Optional `first_name` tests display fallback; optional `raw_update` tests updates without messages.
- `GET /_control/sent?chat_id=111`: `{"messages":[{"message_id":1,"chat_id":111,"text":"..."}]}`.
- `POST /_control/fail`: `{"method":"sendMessage","status":429,"retry_after":1,"count":1}`; optional `description` tests error handling.
- `GET /_control/offsets`: JSON array of offsets; omitted offsets appear as `null`.

For automated tests, `--port 0 --ready-file <path>` writes the assigned
loopback base URL once listening. Each test should start its own server and
kill/wait for its child on cleanup.

Media calls: `getFile`, `sendPhoto`, `sendDocument`, `sendVoice`, and `sendAudio`.
Inject `media: {type, bytes_base64, mime_type, file_name, declare_size, caption}` with
`/_control/inject`. Supported types are `photo`, `document`, `voice`, `audio`,
`video`, `video_note`, and `animation`; `sticker`, `location`, `contact`, and `poll`
produce unsupported objects. Photos have small, large, medium sizes in that order.
`declare_size` overrides metadata only; downloads retain the exact injected bytes.

`getFile` accepts `file_id` in a GET query or POST JSON; download its `file_path`
from `/file/botTEST:FAKE/<file_path>`. Expire metadata with
`POST /_control/file-expire` and JSON `{"file_id":"FAKEFILE1"}`.
Media sends require multipart `chat_id` and the matching file field, plus optional
`caption`. `/_control/sent` records `method`, `filename`, `mime`, `size`, and
lowercase `sha256`, never file bytes. Method failure injection applies to media.
Bodies are capped at 60,000,000 bytes. Encoded token path segments are accepted.

Run regressions with `node --test tools/fake_telegram/server_test.mjs`.
