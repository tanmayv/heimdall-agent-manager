# Fake WhatsApp Cloud API

Requires Node 20 or newer; no dependencies. The CLI binds only to loopback.
Use it with an isolated local hub, with test credentials.

```bash
node tools/fake_whatsapp/server.mjs --port 18098 \
  --access-token TEST-WA-TOKEN --app-secret test-app-secret \
  --verify-token test-verify-token-0001 \
  --phone-number-id 100000000000001 --business-account-id 200000000000002 \
  --display-phone 15550100001 \
  --webhook-url http://127.0.0.1:18181/api/v1/channels/whatsapp/webhook
```

Set the isolated hub's WhatsApp API base to `http://127.0.0.1:18098`.
`--port 0 --ready-file <path>` writes the assigned base URL once listening.
Import `createFakeWhatsApp(options)` from `server.mjs` for an unstarted
`http.Server`; the option names and defaults match spec section 17.

Graph requests accept any `/v<major>.<minor>/` prefix and require
`Authorization: Bearer TEST-WA-TOKEN`. Identity is
`GET /v27.0/100000000000001?fields=display_phone_number,verified_name`.
Text, reaction, template and read requests use
`POST /v27.0/100000000000001/messages`. Address text/reaction/template
requests with exactly one of `to: "+15551230001"` or `recipient: "US.alice"`.
Read requests use `status: "read"` and `message_id`.

Control endpoints (JSON POST unless marked GET):

| Endpoint | Body / result |
| --- | --- |
| `/_control/inject` | `{"from":"15551230001","user_id":"US.alice","name":"Alice","type":"text","text":"hi","timestamp":1763452800,"id":"wamid.X","omit_from":false}`; defaults to current time and a fresh id. Signs and posts the spec webhook shape; returns `{id,status,body}`. `omit_from:true` produces a BSUID-only message. |
| `/_control/replay` | `{"id":"wamid.X"}`; reuses the first exact bytes and signature for that id. |
| `/_control/post` | `{"body":"<raw>","signature":"sha256=…"}`; null signature omits the header. |
| `/_control/challenge` | `{"verify_token":"test-verify-token-0001","challenge":"1158201444"}`; returns status, body and content type from the webhook GET. |
| GET `/_control/sent?to=15551230001` | `{messages:[{id,to,type,text,template,reaction,reaction_message_id}]}` in send order; filter optional. |
| GET `/_control/reads` | `{reads:[{message_id}]}`. |
| `/_control/templates` | `{"approved":["ninjy_reply_waiting"]}` replaces the initially empty approved set. Only language `en` succeeds. |
| `/_control/window` | `{"to":"15551230001","open":false}` sticky-closes a key; true clears the sticky flag. |
| `/_control/window-mode` | `{"mode":"sync"}` (default) or `{"mode":"async"}`. |
| `/_control/fail` | `{"type":"text","http_status":400,"code":131056,"count":1}` queues counted errors for that type. |
| GET `/_control/versions` | `{versions:["v27.0"]}`, distinct versions observed. |

Inject a fresh message before sending text: windows are open for 24 hours
after its timestamp, unless sticky-closed. Injection updates both the phone
and BSUID keys. Clearing a sticky close does not refresh the timestamp.
A closed window refuses text synchronously with 131047, or accepts it and
posts a signed failed-status webhook after 50 ms in async mode.
Templates and reactions can be recorded without an open window.
A reachable `webhookUrl` is required for injection, replay, challenge and raw
posting. The fake never prints credentials or webhook contents.

```bash
node --test tools/fake_whatsapp/server_test.mjs
```

Tests start their own loopback servers and close them on cleanup. Odin adapter
tests spawn one child containing the fake and a local webhook sink, and kill/wait
that child at fixture teardown. No Meta endpoint or live hub is involved.
