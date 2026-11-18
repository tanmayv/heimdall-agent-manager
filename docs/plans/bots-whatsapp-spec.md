# Bots: WhatsApp Cloud API adapter — implementation spec

**Status:** spec for implementation. Nothing in it is implemented yet.
**Branch:** every ticket lands on `feat/bots`. Never commit to `main`. Never push.
**Base commit checked:** `d3c9ad2b` (`feat/bots`: slice 1, settings UI polish, 👀 read reaction). Every `path:line` reference was read in that checkout. Paths are relative to the repository root. Section 26 lists every reference with the symbol it points at.
**Sources:** the approved plan on `task_18e9089629f674af` (comment `cmt_18e908b5fac6a447`) and the user decisions on the same task (comment `cmt_18e908d62b0039da`). The slice 1 spec `docs/plans/bots-slice-1-spec.md` describes what exists. **This document replaces the plan for implementers.** An implementer needs nothing else.

## 0. How to read this spec

- **MUST**, **MUST NOT** and **SHOULD** are normative. Everything else is explanation.
- Every new name (table, column, route, constant, proc, file, env variable, flag, copy string, `data-debug-id`) is fixed here. Use it exactly as written.
- Section 22 lists the tickets. Each ticket names the sections it implements, the files it may touch, the files it must not touch, its named tests, its done criteria and its dependencies.
- Text marked **Assumption** has not been verified. Each assumption names the ticket that verifies it and the fallback that ticket builds if it is false (section 24).
- Section 25 lists open questions for the coordinator. None blocks a ticket. Each has a default, and the default is what gets built.
- WhatsApp Cloud API facts are in section 2, each with the Meta documentation URL it was read on (2026-11-18). A fact marked **unverified** has a fallback in the same row.

Abbreviation used in URLs: **`D/`** = `https://developers.facebook.com/documentation/business-messaging/whatsapp/`. Meta moved its WhatsApp docs there from `developers.facebook.com/docs/whatsapp/...`; the old URLs redirect.

## 1. Scope

### 1.1 What this slice delivers

A user who has the `bots` experiment on and a bot can:

1. connect one WhatsApp number to their bot from Settings > Bots: the page shows a `wa.me` link and a QR code that open WhatsApp with a prefilled message carrying a single-use code;
2. talk to the bot from WhatsApp exactly as from Telegram: same delivery engine, same placement, same failover, same "no machine" notice;
3. keep Telegram connected at the same time. A reply goes to the channel the message came from;
4. see 👀 and blue ticks in WhatsApp when the bot reads their message;
5. get a reply that the bot wrote after WhatsApp's 24-hour window closed: the hub keeps it, shows it in Settings > Bots, sends an approved template message saying a reply is waiting, and delivers the kept reply when the user writes again;
6. disconnect from Settings or by sending `disconnect` in the chat.

The hub operator configures one Meta app, one WhatsApp business phone number and a public HTTPS webhook. Staging (`hub.mundus.in`, Meta test number) is the only target of this slice.

### 1.2 Non-goals (MUST NOT be built)

- A production Meta app, business verification or a real (non-test) number. Prod onboarding is separate (plan decision 4).
- Media, voice, documents, locations, buttons, lists, interactive messages, typing indicators, group chats.
- Proactive messages other than the one re-engagement template in section 12.
- Webhook mTLS or IP allow-listing (section 25, Q3).
- Any bridge change. The bridge's notice text stays `"New Telegram message for you — …"` (`src/bridge/bot_delivery.odin:14`); the bot template explains that it also covers WhatsApp (section 11.6). Section 25, Q1.
- Any change to Telegram behaviour, wire format or copy (section 7.2 lists the mechanical Telegram edits that keep behaviour identical).
- Changes to the delivery engine (`delivery.odin`, `placement.odin`), the bridge protocol, `bot_deliver`, or the agent placement rules.

### 1.3 Requirements

From the plan, unchanged:

| ID | Requirement |
|---|---|
| REQ-WA-1 | The hub exposes a WhatsApp webhook: the verification handshake answers Meta's challenge only for the configured verify token |
| REQ-WA-2 | Every webhook POST is rejected unless its signature matches the app secret over the raw body |
| REQ-WA-3 | An inbound message is stored before the webhook is acknowledged and reaches the bot once (dedupe on WhatsApp's message id) |
| REQ-WA-4 | A user pairs one WhatsApp number through a single-use, expiring code sent as their first message, and can disconnect from the UI or the chat |
| REQ-WA-5 | The bot can send text only to its owner's paired WhatsApp number |
| REQ-WA-6 | Delivery, placement, failover and the "no machine" notice work unchanged; only the channel differs |
| REQ-WA-7 | A reply refused because the 24-hour window closed is kept, marked, and shown to the user; it is never silently dropped |
| REQ-WA-8 | Messages the agent reads are marked read in WhatsApp and get the read reaction, best effort |
| REQ-WA-9 | Non-text messages get a fixed "text only" reply |
| REQ-WA-10 | WhatsApp is reached only through the provider-neutral adapter; bot logic has no WhatsApp-specific code |
| REQ-WA-11 | Tokens and the app secret come from files or env, are never logged, and the feature stays behind the `bots` experiment |
| REQ-WA-12 | Tests run against a fake WhatsApp server; the public webhook is rate limited |

Section 23 maps each requirement to sections and tickets.

### 1.4 User decisions applied (final)

| # | Decision (2026-11-18) | Where applied |
|---|---|---|
| U1 | A reply goes to the channel the message came from | section 11 |
| U2 | 24-hour window closed: keep the reply, show it in the Ninjy UI, AND send an approved template message saying a reply is waiting; when the user writes, the kept reply is delivered. The spec fixes the template name, language and text, and says what happens while the template is not approved | section 12 |
| U3 | One chat per provider per user (plan recommendation 2) | sections 5, 10 (the existing index `channel_bindings_active_owner` on `(owner_user_id, provider)`, `209_bots.sql:39-40`, already enforces it) |
| U4 | Staging only; a separate prod app later (plan recommendation 4) | sections 1.2, 22 W8 |
| U5 | Keep building on `feat/bots` (plan recommendation 5) | header, section 22 |

## 2. WhatsApp Cloud API facts used (verified 2026-11-18)

Every fact this spec relies on. "Verified" means read on the cited Meta page on 2026-11-18. The adapter and the fake server (both W3) MUST follow these rows exactly.

| # | Fact | Source | Status / fallback |
|---|---|---|---|
| F1 | Verification handshake: Meta sends `GET <callback>?hub.mode=subscribe&hub.challenge=<challenge>&hub.verify_token=<token>`. If the token matches, respond `200` with the `hub.challenge` value as the body; otherwise respond with any status other than `200`. `hub.mode` is always `subscribe`. The example challenge is `1158201444` | `D/webhooks/create-webhook-endpoint`; `https://developers.facebook.com/docs/graph-api/webhooks/getting-started` | Verified. The content type is not specified; the hub answers `text/plain` |
| F2 | Every webhook POST carries `X-Hub-Signature-256: sha256=<hex>`: HMAC-SHA256 of the POST body keyed by the app secret. The example hex is lowercase. Respond `200` when valid; anything else otherwise | `D/webhooks/create-webhook-endpoint` | Verified. The hub computes the HMAC over the exact raw request bytes, never over re-serialized JSON (Messenger documents escaped-Unicode signing: `https://developers.facebook.com/docs/messenger-platform/webhooks`; raw bytes are correct in both cases) |
| F3 | On a non-200 response or delivery failure, Meta retries "with decreasing frequency until the request succeeds, for up to 7 days", and "these retries can result in duplicate webhook notifications". Unacknowledged events are dropped after 7 days. There is no API to fetch past webhooks | `D/webhooks/overview`; `D/webhooks/create-webhook-endpoint`; `D/throughput` | Verified. The hub dedupes every event (section 9.5) and keeps dedupe keys 7 days |
| F4 | No numeric webhook response timeout is documented. Meta's latency standard: median under 250 ms, under 1% above 1 s. Deliveries are concurrent | `D/throughput` | Verified. The hub stores and returns `200` without any provider call in the request (section 9) |
| F5 | Payloads can be up to 3 MB and batch up to 1,000 updates; batching is not guaranteed | `D/webhooks/overview` | Verified. Body limit 4 MiB (section 9.2) |
| F6 | Text message webhook shape: `object:"whatsapp_business_account"`, `entry[].id` (the WhatsApp Business Account id), `entry[].changes[].field:"messages"`, `value.metadata.phone_number_id`, `value.metadata.display_phone_number` (digits), `value.contacts[]{profile.name, wa_id, user_id}`, `value.messages[]{from, from_user_id, id ("wamid.…"), timestamp (string, Unix seconds), type, text.body}`. Full example in section 8.6 | `D/webhooks/overview`; `D/webhooks/reference/messages/text` | Verified |
| F7 | `from` and `wa_id` are omitted when the user adopted a username and their phone number is unavailable. The stable user key is the business-scoped user id (BSUID) in `from_user_id` / `contacts[].user_id`, format `<country>.<up to 128 alphanumerics>`. The phone number is still included when the business and the user messaged each other in the last 30 days. A send can address a BSUID with `"recipient":"<BSUID>"` instead of `"to"` | `D/business-scoped-user-ids` | Verified. Section 8.4 fixes how the hub keys chats |
| F8 | Message `type` values: `audio`, `button`, `contacts`, `document`, `edit`, `group`, `image`, `interactive`, `location`, `order`, `reaction`, `revoke`, `sticker`, `system`, `text`, `unsupported`, `video` | `D/webhooks/reference/messages/` (one page per type) | Verified |
| F9 | Status webhook: `value.statuses[]{id, status, timestamp, recipient_id, recipient_user_id, errors[]{code, title, message, error_data.details}}`; `status` ∈ `sent`, `delivered`, `read`, `failed`, `played`. Failed example in section 8.6 | `D/webhooks/reference/messages/status` | Verified |
| F10 | Send text: `POST https://graph.facebook.com/<version>/<PHONE_NUMBER_ID>/messages`, `Authorization: Bearer <token>`, body `{"messaging_product":"whatsapp","recipient_type":"individual","to":"<phone>","type":"text","text":{"preview_url":false,"body":"<text>"}}`. Response `{"messaging_product":"whatsapp","contacts":[{"input":"…","wa_id":"…"}],"messages":[{"id":"wamid.…"}]}`. `body` maximum 4096 characters. Include `+` and the country code in `to`. Success means accepted, not delivered | `D/messages/text-messages`; `D/messages/send-messages` | Verified |
| F11 | Mark as read: same endpoint, body `{"messaging_product":"whatsapp","status":"read","message_id":"<wamid>"}`, response `{"success":true}`. Marking a message read also marks earlier messages in the conversation read. Only within 30 days of receipt | `D/messages/mark-message-as-read` | Verified. The hub marks only the newest newly-read message (section 13) |
| F12 | Reaction: same endpoint, body `{"messaging_product":"whatsapp","recipient_type":"individual","to":"<phone>","type":"reaction","reaction":{"message_id":"<wamid>","emoji":"👀"}}`. Reactions are service messages and need an open customer service window. A failed reaction is reported by webhook with `131009` | `D/messages/reaction-messages`; `D/messages/send-messages` | Verified |
| F13 | Error JSON: `{"error":{"message":"…","type":"OAuthException","code":<int>,"error_data":{"messaging_product":"whatsapp","details":"…"},"fbtrace_id":"…"}}`. Build handling on `code`. Errors arrive synchronously, asynchronously by webhook, or both | `D/support/error-codes` | Verified |
| F14 | Codes: `131047` more than 24 hours since the recipient last replied (send a template instead); `131026` undeliverable; `132001` template does not exist in that language or is not approved; `132015` template paused; `132016` template disabled; `130429` throughput reached; `131056` pair rate limit (1 message every 6 s to the same user, `D/about-the-platform`); `190` access token expired; `100` invalid parameter; `131009` parameter value invalid; `368` account restricted; `131062` BSUID recipient not supported for this message | `D/support/error-codes`; `D/business-scoped-user-ids` | Verified |
| F15 | Whether `131047` comes back in the send response (HTTP 400) or only later as a `failed` status | `D/support/error-codes` says only "synchronously, asynchronously, or both" | **Unverified.** The hub handles both paths (sections 12.3 and 12.6) |
| F16 | `131030` = recipient not in the test number's allowed list | not on the current error page; third-party sources only | **Unverified.** The adapter maps it to `.Chat_Unavailable`; if Meta returns another code, it falls in the generic 4xx row (`.Invalid_Request`) and the send still fails visibly |
| F17 | Template send body: `{"messaging_product":"whatsapp","recipient_type":"individual","to":"<phone>","type":"template","template":{"name":"<name>","language":{"code":"<locale>"}}}`. The locale MUST equal the one the template was created with (`en` and `en_US` are different). Names match `^[a-z0-9_]+$`, at most 512 characters. A template must be `APPROVED`; pending or rejected templates fail with `132001` | `D/templates/overview`; `D/templates/template-management`; `D/templates/supported-languages` | Verified, except that a send of a template without parameters may omit `components`: **unverified** (Meta's examples always show `components` for templates with parameters; `hello_world` is sent without). Fallback in Assumption A6 |
| F18 | Utility templates must be non-promotional and specific to or requested by the user; generic wording is recategorized as marketing. Marketing templates are not delivered to US numbers | `D/templates/template-categorization`; `D/templates/marketing-templates/per-user-limits` | Verified. The template text in 12.4 ties itself to the user's own message |
| F19 | Pricing since 2026-10-01: utility templates sent inside an open window are charged; service messages are free up to 1,000 per business phone number per month | `D/pricing` | Verified. Staging volume is far below this |
| F20 | Graph API versions: v27.0 released 2026-11-04 (latest; all current WhatsApp examples use it); v26.0 2026-07-29; v23.0 available until 2027-10-08. A request without a version uses the newest available | `https://developers.facebook.com/docs/graph-api/changelog` | Verified. The hub pins `v27.0` |
| F21 | Display number: `GET https://graph.facebook.com/<version>/<PHONE_NUMBER_ID>?fields=display_phone_number,verified_name` returns `{"display_phone_number":"15555555555","verified_name":"…","id":"…"}`. Other endpoints return the number formatted (`"+1 631-555-5555"`) | `D/business-phone-numbers/phone-numbers` | Verified. The adapter keeps only digits |
| F22 | The Meta test number and test account are created automatically, with relaxed limits and no payment method needed for templates. The temporary dashboard token "expires quickly". A permanent token comes from a system user with `business_management`, `whatsapp_business_messaging`, `whatsapp_business_management`, assigned the app and the WhatsApp account | `D/about-the-platform`; `D/get-started`; `D/access-tokens` | Verified |
| F23 | The test number can only message up to 5 recipient numbers that were added and verified by code in the dashboard | third-party sources only | **Unverified.** Staging test users MUST be added in the dashboard (W8 step M5); nothing in the hub depends on the number |
| F24 | Webhook setup: App Dashboard > WhatsApp > Configuration (newer apps: Use cases > Customize > Configuration): Callback URL, Verify token, subscribe the `messages` field. The callback MUST be HTTPS with a valid certificate; self-signed is refused. `POST /<version>/<WABA_ID>/subscribed_apps` subscribes the app to the account and returns `{"success":true}`. Some webhooks are not sent while the app is in Dev mode | `D/webhooks/create-webhook-endpoint`; `D/webhooks/overview`; `D/solution-providers/manage-webhooks` | Verified |
| F25 | Click to chat: `https://wa.me/<number>?text=<urlencoded text>`; the number in full international format without `+`, zeros prefix, brackets or dashes | `https://faq.whatsapp.com/5913398998672934` | Verified |

### 2.1 Pinned constants

Defined in `src/hub/service/channel/whatsapp.odin` (W3):

```odin
WHATSAPP_GRAPH_VERSION :: "v27.0"
WHATSAPP_DEFAULT_API_BASE :: "https://graph.facebook.com"
WHATSAPP_REENGAGE_TEMPLATE_NAME :: "ninjy_reply_waiting"
WHATSAPP_REENGAGE_TEMPLATE_LANGUAGE :: "en"
WHATSAPP_PAIRING_PREFIX :: "Connect Ninjy"
WHATSAPP_REPLY_WINDOW_MS :: 86_400_000
WHATSAPP_FEEDBACK_TIMEOUT_MS :: 1000
WHATSAPP_SEND_TIMEOUT_MS :: 15_000
WHATSAPP_IDENTITY_TIMEOUT_MS :: 10_000
WHATSAPP_PAIR_RATE_RETRY_MS :: 6000
WHATSAPP_THROUGHPUT_RETRY_MS :: 5000
```

## 3. Decisions

### D1. Push intake through a stored event queue

**Decision.** The webhook handler verifies the signature, parses the payload into `channel.Inbound` events with the adapter, inserts them into a new table `channel_push_events` with `INSERT OR IGNORE` on `event_key`, commits, and only then answers `200`. A hub thread, the **intake** (section 9.6), drains unprocessed events and runs the existing inbound pipeline on them: map to `channel_messages` rows, commit rows and "processed" marks in one transaction, then run side effects (pairing, notices, held-reply release) and `delivery_on_inbound`.

**Why.**

- REQ-WA-3: the event is durable before Meta gets `200`. Meta retries for 7 days and may send duplicates (F3), so the queue's unique `event_key` drops them before any side effect runs. This also covers pairing messages and notices, which Telegram cannot dedupe (slice 1 spec 9.3 "Duplicate side effects").
- F4: the request never waits for Graph calls. Pairing replies and held-reply delivery happen on the intake thread.
- The intake reuses the Telegram poller's order exactly: commit, then side effects, then deliveries (`src/hub/service/bots/poller.odin:53-73`). Inbound rules stay in one place (`inbound.odin`, `pairing.odin`), shared by both providers.

**Rejected.** Processing in the request handler: Graph calls inside the request (F4) and no dedupe for side effects. A `poll` proc on the WhatsApp adapter that reads the queue: adapters live in `package channel`, which has no repository access, and the queue is hub state.

### D2. Chat and user keys for WhatsApp

**Decision.** For each inbound WhatsApp message:

- `external_user_id` = `from_user_id` when present and non-empty, else `from`.
- `external_chat_id` = `from` when present and non-empty, else `from_user_id`.

A binding is looked up by `(provider, external_chat_id)` first and, when not found, by `(provider, external_user_id)` (new repository proc `binding_get_active_by_user`, section 6.3). Sends address the chat id: an all-digit chat id is sent as `"to":"+<digits>"`, any other chat id as `"recipient":"<chat id>"` (F7, F10).

**Why.** F7: the phone number is the address Meta documents for every message type, and it stays present while the user and the bot talk (30-day rule). The BSUID is the stable identity, so it is the user key and the fallback lookup. The fallback lookup is provider-neutral and changes nothing for Telegram, where a private chat id equals the user id.

### D3. Reply routing by origin (U1)

**Decision.**

- `channel read` returns the pending messages of **one** channel: the channel of the oldest pending message (section 11.2). Each returned message carries `"channel"`.
- `channel send` goes to the channel of the oldest message that was read and is not yet replied (section 11.3). It marks replied only that channel's read messages.
- Messages from the other channel stay pending. Because they stay pending, the existing rule R3 (slice 1 spec 11.3; `src/hub/service/bots/inbound.odin:118-122`) opens a new delivery after the current one is acted, and the bot is woken again for them.

**Why.** No new parameter for the bot to get wrong, no change to `ham-ctl channel send` arguments, and no bridge change: the bridge sees a read with a non-empty `messages` array and a send, as before (`src/bridge/bot_delivery.odin:447`, `src/bridge/wrapper_endpoint.odin:570`). Each channel's messages are answered on that channel even when the user writes on both at once.

### D4. The 24-hour window (U2)

**Decision.** Provider-neutral, driven by two adapter fields: `reply_window_ms` (WhatsApp: 24 h; Telegram: 0 = no window) and `send_reengage` (WhatsApp: sends the fixed template; Telegram: nil).

1. Every inbound event from a bound chat stamps `channel_bindings.last_inbound_at` with the message time.
2. A recorded send (an agent reply) to a binding whose window is closed (section 12.2), or whose send fails with `.Window_Closed`, stores the unsent chunks as outbound rows with `send_state='held'` instead of failing. The send route answers `200` with `"held":true`. The delivery is acted as usual: the bot did answer.
3. After holding, the hub sends the re-engagement template once per closed window (section 12.4).
4. When the user writes again, the intake sends the held rows of that binding, oldest first, before handing the new message to the bot (section 12.5).
5. Settings > Bots shows held replies and the reminder state (section 16).
6. A `failed` status with code `131047` for a reply that was accepted earlier turns that row into a held row (section 12.6, F15).

**While the template is not approved:** the template send fails with `132001` (F17). The hub sets `channel_bindings.reengage_error='template_unavailable'`, logs it, and keeps the reply held. The UI shows the held reply and says the reminder could not be sent. The held reply is still delivered as soon as the user writes. The hub tries the template again on the next held reply, not on a timer.

### D5. Pairing by first message

**Decision.** The pairing code is the slice 1 code: 32 lowercase hex characters from 16 random bytes, stored as its SHA-256, 10-minute TTL, single use (`src/hub/service/bots/pairing.odin:25-44`). The WhatsApp link is `https://wa.me/<digits>?text=Connect%20Ninjy%20<code>`. The adapter maps a text whose trimmed form starts with `Connect Ninjy` (ASCII case-insensitive) followed by whitespace, or equals it, to `Inbound{kind=.Start, text=<rest, trimmed, lower-cased>}`. The existing pairing rules then run unchanged (slice 1 spec 9.6; `pairing.odin:69-105`), with WhatsApp copy.

### D6. Gating

- **Hub-wide:** the webhook route answers `404` unless WhatsApp is configured (all five secrets present, section 14) **and** `experiment_count_enabled("bots") > 0`. The intake thread runs under the same condition (section 9.7).
- **Per owner:** unchanged slice 1 rules. An event from a chat bound to an owner with the experiment off is processed and dropped (inbound rule 4, `inbound.odin:46`); a pairing for such an owner gets `COPY_PAIR_NOT_ENABLED` (`pairing.odin:82`).
- Section 20 lists every gated and ungated change.

### D7. No bridge change

The bridge already relays `agent.channel.*` (`src/bridge/agent_api.odin:238`, `:364`) and observes reads by a non-empty `data.messages` (`src/bridge/bot_delivery.odin:447`). The new response fields (`channel`, `held`) are additive. The bridge's notice text stays Telegram-worded; the bot template explains it (section 11.6). No bridge release is needed, so staging needs no bridge binary swap.

## 4. Architecture and message lifecycle

```text
Meta Cloud API ──POST /api/v1/channels/whatsapp/webhook──▶ hub transport (bot_webhook_handlers.odin)
   ▲                                                       │ rate limit, size, signature (adapter.push_parse)
   │                                                       ▼
   │                                    bots service: bots_push_receive → channel_push_events (tx) → 200
   │                                                       │ signal
   │                                                       ▼
   │                                    intake thread: events → inbound rows (shared rules) → push_batch_commit (tx)
   │                                                       │ then: release held replies, side effects, delivery_on_inbound
   │                                                       ▼
   │                                    existing delivery engine → bridge → bot → ham-ctl channel read/send
   └──────── Graph API: send text / template / mark read / reaction ◀── adapter (whatsapp.odin)
```

**Happy path:**

1. The user sends "hi". Meta POSTs a signed payload. The hub verifies, stores event `whatsapp:<phone_number_id>:<wamid>`, returns `200`.
2. The intake maps it to an inbound `channel_messages` row (`provider_update_key` = the event key), stamps `last_inbound_at`, marks the event processed, commits. It calls `delivery_on_inbound`.
3. The delivery engine dispatches to a bridge, which wakes the bot (unchanged).
4. The bot runs `ham-ctl channel read`. The read returns the WhatsApp message with `"channel":"whatsapp"`. The hub marks the newest newly-read message read in WhatsApp and reacts 👀 to each newly-read message (section 13).
5. The bot runs `ham-ctl channel send --text "…"`. The reply-routing rule picks the WhatsApp binding. The window is open; the adapter sends the text. The hub marks the WhatsApp messages replied and the delivery acted.

## 5. Migration `210_bots_whatsapp.sql`

### 5.1 File and registration

- **File:** `src/hub/repository/sqlite/migrations/210_bots_whatsapp.sql`. The highest migration at the base commit is `209_bots.sql`. If `210_*` exists when W1 starts, W1 MUST use the next free number and change this spec's references in the same commit.
- **Registration** in `src/hub/repository/sqlite/migrations.odin`:
  1. Add `MIGRATION_210_BOTS_WHATSAPP :: #load("migrations/210_bots_whatsapp.sql", string)` after `MIGRATION_209_BOTS` (`migrations.odin:664`).
  2. Append `"210_bots_whatsapp.sql"` to `migration_order` after `"209_bots.sql"` (`:879`) and raise the array length from 213 to 214 (`:666`).
  3. Add `if name == "210_bots_whatsapp.sql" do return strings.clone(MIGRATION_210_BOTS_WHATSAPP)` above the `209` line in `migration_sql` (`:1379`).
  4. Add a skip-guard next to the `169` guard (`:918-921`), keyed on the **last** object the file creates:
     ```odin
     // 210 commits atomically; its last index lets startup repair a crash between commit and ledger insert.
     if name == "210_bots_whatsapp.sql" && sqlite_object_exists(conn, "channel_push_events_pending") {
         mark_migration_applied(conn, name)
         continue
     }
     ```
  5. On `exec` failure roll back like 169 (`:1328-1329`): change that line to `if name=="169_provider_profiles.sql" || name=="210_bots_whatsapp.sql" do _=exec(conn,"ROLLBACK;")`.

### 5.2 SQL (verbatim)

The file runs in one transaction, so it is fully applied or absent. Rebuilding is needed because SQLite cannot change a `CHECK` constraint in place. No table references these three tables by foreign key and no trigger or view names them (`209_bots.sql` is the only migration that mentions them; it creates no trigger), so `DROP TABLE` and `RENAME` touch nothing else.

```sql
-- 210_bots_whatsapp.sql: WhatsApp channel for bots (experiment "bots").
-- Rebuilds channel_bindings, channel_pairings and channel_messages to widen their
-- CHECK constraints, carrying every existing row unchanged, and adds the push queue.
BEGIN IMMEDIATE;

CREATE TABLE channel_bindings_next (
  binding_id         TEXT PRIMARY KEY,                  -- "chb_..."
  owner_user_id      TEXT NOT NULL,
  bot_id             TEXT NOT NULL,
  provider           TEXT NOT NULL CHECK (provider IN ('telegram','whatsapp')),
  external_chat_id   TEXT NOT NULL,                     -- Telegram chat.id; WhatsApp phone digits or BSUID (D2)
  external_user_id   TEXT NOT NULL,                     -- Telegram from.id; WhatsApp BSUID or phone digits (D2)
  external_display   TEXT NOT NULL DEFAULT '',
  state              TEXT NOT NULL CHECK (state IN ('active','revoked')),
  created_at         TEXT NOT NULL,
  revoked_at         TEXT NOT NULL DEFAULT '',
  last_inbound_at    TEXT NOT NULL DEFAULT '',          -- RFC 3339 UTC of the user's latest message
  reengage_sent_at   TEXT NOT NULL DEFAULT '',          -- template sent for the current closed window
  reengage_error     TEXT NOT NULL DEFAULT '' CHECK (reengage_error IN ('','template_unavailable','send_failed'))
);
INSERT INTO channel_bindings_next
  (binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at)
  SELECT binding_id, owner_user_id, bot_id, provider, external_chat_id, external_user_id, external_display, state, created_at, revoked_at
  FROM channel_bindings;
DROP TABLE channel_bindings;
ALTER TABLE channel_bindings_next RENAME TO channel_bindings;
CREATE UNIQUE INDEX channel_bindings_active_chat
  ON channel_bindings(provider, external_chat_id) WHERE state = 'active';
CREATE UNIQUE INDEX channel_bindings_active_owner
  ON channel_bindings(owner_user_id, provider) WHERE state = 'active';
CREATE INDEX channel_bindings_active_user
  ON channel_bindings(provider, external_user_id) WHERE state = 'active';

CREATE TABLE channel_pairings_next (
  code_hash      TEXT PRIMARY KEY,
  owner_user_id  TEXT NOT NULL,
  bot_id         TEXT NOT NULL,
  provider       TEXT NOT NULL CHECK (provider IN ('telegram','whatsapp')),
  created_at     TEXT NOT NULL,
  expires_at     TEXT NOT NULL,
  consumed_at    TEXT NOT NULL DEFAULT ''
);
INSERT INTO channel_pairings_next (code_hash, owner_user_id, bot_id, provider, created_at, expires_at, consumed_at)
  SELECT code_hash, owner_user_id, bot_id, provider, created_at, expires_at, consumed_at FROM channel_pairings;
DROP TABLE channel_pairings;
ALTER TABLE channel_pairings_next RENAME TO channel_pairings;
CREATE INDEX channel_pairings_owner ON channel_pairings(owner_user_id, provider);

CREATE TABLE channel_messages_next (
  message_id           TEXT PRIMARY KEY,
  binding_id           TEXT NOT NULL,
  owner_user_id        TEXT NOT NULL,
  bot_id               TEXT NOT NULL,
  direction            TEXT NOT NULL CHECK (direction IN ('inbound','outbound')),
  provider_update_key  TEXT NOT NULL DEFAULT '',
  external_message_id  TEXT NOT NULL DEFAULT '',
  body                 TEXT NOT NULL,
  body_purged          INTEGER NOT NULL DEFAULT 0 CHECK (body_purged IN (0,1)),
  send_state           TEXT NOT NULL DEFAULT '' CHECK (send_state IN ('','pending','sent','failed','held')),
  send_error           TEXT NOT NULL DEFAULT '',
  created_at           TEXT NOT NULL,
  read_at              TEXT NOT NULL DEFAULT '',
  replied_at           TEXT NOT NULL DEFAULT ''
);
INSERT INTO channel_messages_next
  (message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at)
  SELECT message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at
  FROM channel_messages;
DROP TABLE channel_messages;
ALTER TABLE channel_messages_next RENAME TO channel_messages;
CREATE UNIQUE INDEX channel_messages_update_key
  ON channel_messages(provider_update_key) WHERE provider_update_key <> '';
CREATE INDEX channel_messages_bot_pending
  ON channel_messages(bot_id, direction, replied_at, created_at);
CREATE INDEX channel_messages_binding_held
  ON channel_messages(binding_id, created_at) WHERE send_state = 'held';
CREATE INDEX channel_messages_outbound_external
  ON channel_messages(binding_id, external_message_id) WHERE direction = 'outbound' AND external_message_id <> '';

CREATE TABLE channel_push_events (
  seq                  INTEGER PRIMARY KEY AUTOINCREMENT,
  provider             TEXT NOT NULL CHECK (provider IN ('whatsapp')),
  event_key            TEXT NOT NULL UNIQUE,            -- section 8.4
  kind                 TEXT NOT NULL CHECK (kind IN ('text','start','disconnect','unsupported','delivery_failed')),
  external_chat_id     TEXT NOT NULL,
  external_user_id     TEXT NOT NULL DEFAULT '',
  external_message_id  TEXT NOT NULL DEFAULT '',
  sender_display       TEXT NOT NULL DEFAULT '',
  body                 TEXT NOT NULL DEFAULT '',        -- plaintext until processed, then ''
  provider_code        INTEGER NOT NULL DEFAULT 0,      -- delivery_failed: Graph error code
  provider_time        TEXT NOT NULL DEFAULT '',        -- RFC 3339 UTC of the provider timestamp
  received_at          TEXT NOT NULL,
  processed_at         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX channel_push_events_pending
  ON channel_push_events(provider, seq) WHERE processed_at = '';

COMMIT;
```

- **Existing rows:** every Telegram binding, pairing and message keeps all its values. New binding columns are `''`. Staging's live Telegram pairing survives (plan risk "schema change").
- **Rollback.** A hub rollback to a build without 210 keeps working: the old build reads the same column names it knows (`bot_repo_sqlite.odin:478`, `:499` select named columns), and the old CHECKs are gone, so nothing it writes is refused. A rollback does not undo 210, the same as 209 (chain summary "Deploy pitfalls").

## 6. Domain and repository changes (W1)

### 6.1 Domain (`src/hub/domain/bot.odin`)

Add next to `CHANNEL_PROVIDER_TELEGRAM` (`bot.odin:8`):

```odin
CHANNEL_PROVIDER_WHATSAPP :: "whatsapp"
```

Extend `Channel_Binding` (`bot.odin:34`) with three fields after `revoked_at`:

```odin
	last_inbound_at, reengage_sent_at, reengage_error: string,
```

Extend `Channel_Send_State` (`bot.odin:50`) with `Held` as the last member. Its text is `"held"`; extend `channel_send_state_text` and `channel_send_state_from_text` (`bot.odin:172`, `:186`).

Add:

```odin
Channel_Push_Kind :: enum { Text, Start, Disconnect, Unsupported, Delivery_Failed }
// Text forms: "text", "start", "disconnect", "unsupported", "delivery_failed".
channel_push_kind_text :: proc(k: Channel_Push_Kind) -> string
channel_push_kind_from_text :: proc(s: string) -> (Channel_Push_Kind, bool)

Channel_Push_Event :: struct {
	seq: i64,
	provider, event_key: string,
	kind: Channel_Push_Kind,
	external_chat_id, external_user_id, external_message_id, sender_display, body: string,
	provider_code: int,
	provider_time, received_at, processed_at: string,
}
channel_push_event_destroy :: proc(e: ^Channel_Push_Event)

// One binding touched by an inbound event; `at` is the event's provider_time, or now when empty.
Channel_Inbound_Touch :: struct { binding_id, at: string }
```

`channel_binding_destroy` MUST free the three new strings.

### 6.2 Binding reads and writes

- Every `channel_bindings` SELECT in `bot_repo_sqlite.odin` (`:478`, `:499` and the scan helper they share) MUST select the three new columns and fill the new struct fields.
- `binding_activate_sqlite`'s INSERT (`bot_repo_sqlite.odin:1012`) MUST also write `last_inbound_at` from the struct.

### 6.3 New repository procs

Add to `Bot_Repository` (`src/hub/repository/iface/bot_repo.odin`), each with a wrapper proc of the same name in the style of the existing wrappers, and implement them in `bot_repo_sqlite.odin`:

```odin
binding_get:                  proc(ctx: rawptr, binding_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error),
binding_get_active_by_user:   proc(ctx: rawptr, provider, external_user_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error),
bindings_active_for_owner:    proc(ctx: rawptr, owner_user_id: string) -> ([]domain.Channel_Binding, domain.Domain_Error), // ORDER BY provider ASC ('telegram' before 'whatsapp')
binding_set_reengage:         proc(ctx: rawptr, binding_id, reengage_sent_at, reengage_error: string) -> domain.Domain_Error, // only WHERE state='active'
push_events_insert:           proc(ctx: rawptr, events: []domain.Channel_Push_Event) -> (inserted: int, err: domain.Domain_Error), // one tx; INSERT OR IGNORE on event_key
push_events_pending:          proc(ctx: rawptr, provider: string, limit: int) -> ([]domain.Channel_Push_Event, domain.Domain_Error), // processed_at='' ORDER BY seq
push_batch_commit:            proc(ctx: rawptr, rows: []domain.Channel_Message, touches: []domain.Channel_Inbound_Touch, processed_seqs: []i64, processed_at: string) -> (inserted: []string, err: domain.Domain_Error),
push_events_purge_processed:  proc(ctx: rawptr, received_before: string) -> (int, domain.Domain_Error), // DELETE WHERE processed_at<>'' AND received_at<?
messages_mark_replied_binding: proc(ctx: rawptr, bot_id, binding_id, replied_at: string) -> (count: int, err: domain.Domain_Error),
messages_held:                proc(ctx: rawptr, binding_id: string) -> ([]domain.Channel_Message, domain.Domain_Error), // send_state='held' AND body_purged=0 ORDER BY created_at, message_id
message_get_outbound_by_external: proc(ctx: rawptr, binding_id, external_message_id: string) -> (domain.Channel_Message, bool, domain.Domain_Error),
```

**SQL for the non-obvious ones (verbatim):**

```sql
-- push_batch_commit: one BEGIN IMMEDIATE ... COMMIT, statements in this order
INSERT OR IGNORE INTO channel_messages (message_id, binding_id, owner_user_id, bot_id, direction, provider_update_key, external_message_id, body, body_purged, send_state, send_error, created_at, read_at, replied_at)
  VALUES (?, ?, ?, ?, 'inbound', ?, ?, ?, 0, '', '', ?, '', '');                     -- once per row
UPDATE channel_bindings
  SET last_inbound_at = CASE WHEN last_inbound_at < ? THEN ? ELSE last_inbound_at END,
      reengage_sent_at = '', reengage_error = ''
  WHERE binding_id = ? AND state = 'active';                                       -- once per touch: (at, at, binding_id)
UPDATE channel_push_events SET processed_at = ?, body = '' WHERE seq = ? AND processed_at = '';  -- once per seq

-- messages_mark_replied_binding
UPDATE channel_messages SET replied_at = ?
  WHERE bot_id = ? AND binding_id = ? AND direction = 'inbound' AND read_at <> '' AND replied_at = '';

-- binding_get_active_by_user
SELECT <binding columns> FROM channel_bindings WHERE provider = ? AND external_user_id = ? AND state = 'active' ORDER BY created_at DESC LIMIT 1;
```

- `push_batch_commit` returns the `message_id`s that were actually inserted (same contract as `inbound_store_batch`, `bot_repo.odin:91-99`). On any error it rolls back everything, so neither rows, touches nor processed marks persist.
- `messages_purge_older_than` (existing, `bot_repo.odin:138`) MUST additionally run, in the same call, `UPDATE channel_messages SET send_state = 'failed', send_error = 'held_expired' WHERE send_state = 'held' AND body_purged = 1;` after its purge.
- `messages_purge_binding` (existing) MUST also turn held rows of that binding into `failed`/`held_expired` with the same statement restricted to `binding_id = ?`.
- `messages_mark_replied` (existing, `bot_repo.odin:122-128`) stays; no caller uses it after W4.

## 7. Adapter interface change (W1) and Telegram

### 7.1 `src/hub/service/channel/adapter.odin` (verbatim result)

```odin
package channel

Channel_Error_Kind :: enum { None, Transient, Rate_Limited, Unauthorized, Chat_Unavailable, Invalid_Request, Aborted, Window_Closed, Template_Unavailable }

Channel_Error :: struct {
	kind:            Channel_Error_Kind,
	retry_after_ms:  i64,     // set for Rate_Limited
	provider_code:   int,     // provider error code (Telegram error_code, Graph error.code); 0 if none
	message:         string,  // safe to log; never contains a token, a phone number or message text
}

Inbound_Kind :: enum { Text, Start, Disconnect, Unsupported, Delivery_Failed }

Inbound :: struct {
	update_key:          string,  // globally unique per provider, used for dedupe
	external_chat_id:    string,
	external_message_id: string,  // provider message id; Delivery_Failed: the id of OUR outbound message
	external_user_id:    string,
	chat_is_private:     bool,
	sender_display:      string,
	kind:                Inbound_Kind,
	text:                string,  // Text: message text; Start: the pairing payload ("" when none)
	provider_time:       string,  // RFC 3339 UTC of the provider event time; zero value when the provider gives none
	provider_code:       int,     // Delivery_Failed: provider error code; 0 otherwise
}

Identity :: struct {
	bot_user_id:  string,  // Telegram: bot id; WhatsApp: phone_number_id
	bot_username: string,  // Telegram: username without "@"; WhatsApp: display number digits
}

Push_Verdict :: enum { Accepted, Bad_Signature, Bad_Payload }

Channel_Adapter :: struct {
	ctx:      rawptr,
	provider: string, // "telegram" | "whatsapp"
	// Pull providers only (nil for push providers). Blocks up to the provider's long-poll window.
	poll:     proc(ctx: rawptr, cursor: string, cancel: ^bool, allocator := context.allocator) -> (batch: []Inbound, next_cursor: string, err: Channel_Error),
	send_text: proc(ctx: rawptr, external_chat_id: string, text: string) -> (external_message_id: string, err: Channel_Error),
	// Optional read reaction; nil means the provider does not support it.
	react: proc(ctx: rawptr, external_chat_id, external_message_id, emoji: string) -> Channel_Error,
	identity: proc(ctx: rawptr) -> (Identity, Channel_Error),
	pairing_url: proc(ctx: rawptr, identity: Identity, code: string, allocator := context.allocator) -> string,
	// Optional: the message text the user sends to pair (shown in the UI). nil means none (Telegram).
	pairing_text: proc(ctx: rawptr, code: string, allocator := context.allocator) -> string,
	// Push providers only (nil for Telegram).
	// True when mode is "subscribe" and verify_token equals the configured token (constant time).
	push_challenge: proc(ctx: rawptr, mode, verify_token: string) -> bool,
	// Verifies the signature over raw_body, then parses. Batch fields belong to allocator
	// (release with inbound_destroy_batch). Bad_Signature/Bad_Payload return an empty batch.
	push_parse: proc(ctx: rawptr, signature_header, raw_body: string, allocator := context.allocator) -> (batch: []Inbound, verdict: Push_Verdict),
	// Optional read receipt; nil means unsupported.
	mark_read: proc(ctx: rawptr, external_chat_id, external_message_id: string) -> Channel_Error,
	// Optional re-engagement message for a closed reply window; nil means unsupported.
	send_reengage: proc(ctx: rawptr, external_chat_id: string) -> (external_message_id: string, err: Channel_Error),
	// Optional: the error kind for a provider code reported asynchronously (Delivery_Failed). nil = unsupported.
	failure_kind: proc(provider_code: int) -> Channel_Error_Kind,
	// Free-form replies are accepted only this long after the user's last message; 0 = no window.
	reply_window_ms: i64,
}
```

**Contract every adapter MUST meet** (adds to slice 1 spec 8):

1. `push_parse` MUST verify the signature before parsing anything, and MUST NOT perform network I/O.
2. `update_key` MUST be stable for the same provider event across redeliveries.
3. `send_text` maps a closed reply window to `.Window_Closed`; `send_reengage` maps an unusable template to `.Template_Unavailable`; `failure_kind` uses the same mapping for codes reported by webhook.
4. Error `message` values are fixed strings. They never include URLs, response bodies, tokens, phone numbers, BSUIDs or message text.

### 7.2 Telegram stays unchanged

- `telegram_adapter` (`src/hub/service/channel/telegram.odin:19-21`) stays as it is: the new fields are zero (`nil`, `0`), so Telegram has no push intake, no read receipt, no re-engagement, no asynchronous failures and no window.
- `telegram_poll` builds `Inbound` with named fields (`telegram.odin:155-162`), so `provider_time` and `provider_code` stay zero. It MUST NOT be edited.
- `inbound_destroy_batch` (`telegram.odin:94-102`) MUST also `delete(row.provider_time, allocator)`. A zero-value string has no data, so this is safe for Telegram rows. This is the only edit to `telegram.odin`.
- The poller (`poller.odin`) changes only by passing the adapter to the generalized inbound procs (section 10.1). Its order, cursor handling and backoff stay identical.

## 8. WhatsApp adapter (W3)

**File:** `src/hub/service/channel/whatsapp.odin`. HTTP through `httpc` only, like Telegram (`telegram.odin:55-71`). HMAC through `core:crypto/hmac`, as the Paddle webhook does (`src/hub/service/billing/webhook.odin:3`, `:34`).

### 8.1 Struct and constructor

```odin
WhatsApp_Adapter :: struct {
	access_token, app_secret, verify_token: string, // borrowed secrets; never in diagnostics
	phone_number_id, business_account_id: string,   // borrowed configuration
	api_base: string,                               // borrowed; default WHATSAPP_DEFAULT_API_BASE
	mutex: sync.Mutex,
	cached_identity: Identity,                      // heap; freed by whatsapp_destroy
}

whatsapp_adapter :: proc(w: ^WhatsApp_Adapter) -> Channel_Adapter {
	return {ctx = w, provider = "whatsapp", poll = nil, send_text = whatsapp_send_text, react = whatsapp_react,
		identity = whatsapp_identity, pairing_url = whatsapp_pairing_url, pairing_text = whatsapp_pairing_text, push_challenge = whatsapp_push_challenge,
		push_parse = whatsapp_push_parse, mark_read = whatsapp_mark_read, send_reengage = whatsapp_send_reengage,
		failure_kind = whatsapp_failure_kind, reply_window_ms = WHATSAPP_REPLY_WINDOW_MS}
}

// Stop all adapter users before destroying the identity cache.
whatsapp_destroy :: proc(w: ^WhatsApp_Adapter)
```

### 8.2 Requests

Every Graph request:

- URL = `api_base` + path segments `{WHATSAPP_GRAPH_VERSION, phone_number_id, "messages"}` (sends) or `{WHATSAPP_GRAPH_VERSION, phone_number_id}` (identity).
- Header `Authorization: Bearer <access_token>`; JSON bodies with `Content-Type: application/json` (`httpc.json_body`).
- `max_response_bytes = 1 << 20`.
- One shared helper `whatsapp_request(w, verb, segments, query, body, timeout_ms) -> (httpc.Response, Channel_Error)` decodes the error envelope and maps it per 8.5.

| Proc | Request | Timeout | Result |
|---|---|---|---|
| `whatsapp_identity` | `GET …/<pnid>?fields=display_phone_number,verified_name` | `WHATSAPP_IDENTITY_TIMEOUT_MS` | `Identity{bot_user_id = phone_number_id, bot_username = digits of display_phone_number}`; cached for the process lifetime on success; an empty digit string is `.Transient` "invalid whatsapp identity" |
| `whatsapp_send_text` | `POST …/messages` body below | `WHATSAPP_SEND_TIMEOUT_MS` | `messages[0].id` |
| `whatsapp_send_reengage` | `POST …/messages` template body below | `WHATSAPP_SEND_TIMEOUT_MS` | `messages[0].id` |
| `whatsapp_mark_read` | `POST …/messages` read body below | `WHATSAPP_FEEDBACK_TIMEOUT_MS` | `{}` on `{"success":true}` |
| `whatsapp_react` | `POST …/messages` reaction body below | `WHATSAPP_FEEDBACK_TIMEOUT_MS` | `{}` |

**Addressing (D2).** `whatsapp_address(chat_id)`: when `chat_id` is non-empty and all ASCII digits, the JSON gets `"to":"+<chat_id>"`; otherwise `"recipient":"<chat_id>"`. Exactly one of the two keys is present.

**Bodies (verbatim, phone form):**

```json
{"messaging_product":"whatsapp","recipient_type":"individual","to":"+15551230001","type":"text","text":{"preview_url":false,"body":"echo: hi"}}
```
```json
{"messaging_product":"whatsapp","recipient_type":"individual","to":"+15551230001","type":"template","template":{"name":"ninjy_reply_waiting","language":{"code":"en"}}}
```
```json
{"messaging_product":"whatsapp","status":"read","message_id":"wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA="}
```
```json
{"messaging_product":"whatsapp","recipient_type":"individual","to":"+15551230001","type":"reaction","reaction":{"message_id":"wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA=","emoji":"👀"}}
```

- `whatsapp_send_text` refuses (`.Invalid_Request`, "invalid whatsapp message") text that is empty, over 4000 bytes or invalid UTF-8, without a request. 4000 bytes is at most 4000 characters, under the 4096-character limit (F10). The caller already splits at 4000 bytes (`channel_text_chunks`, `src/hub/service/bots/channel_send.odin:15-32`).
- `whatsapp_react` and `whatsapp_mark_read` refuse an empty message id without a request.

**`whatsapp_pairing_text`** returns `WHATSAPP_PAIRING_PREFIX + " " + code` (`"Connect Ninjy 3f2a…"`). **`whatsapp_pairing_url`** returns `"https://wa.me/" + identity.bot_username + "?text=Connect%20Ninjy%20" + code`. The code is lowercase hex, so it needs no encoding.

**`whatsapp_push_challenge`** returns `mode == "subscribe" && len(verify_token) == len(w.verify_token) && crypto.compare_constant_time(verify_token, w.verify_token) == 1`.

### 8.3 Signature (`whatsapp_push_parse`, step 1)

1. `signature_header` MUST be `"sha256="` followed by exactly 64 hex digits (either case). Otherwise `Bad_Signature`.
2. Decode the hex to 32 bytes. `hmac.verify(.SHA256, tag, transmute([]byte)raw_body, transmute([]byte)w.app_secret)` MUST be true. Otherwise `Bad_Signature`.
3. Only then parse JSON (`json.parse`, `parse_integers = false`). A parse failure, or `object != "whatsapp_business_account"`, is `Bad_Payload`.

### 8.4 Mapping a verified payload

For each `entry` whose `id == business_account_id` (other entries are skipped), each `change` with `field == "messages"` (others skipped) and `value.metadata.phone_number_id == phone_number_id` (others skipped):

**Messages** (`value.messages[]`), with `user = from_user_id` (or `from` when absent) and `chat = from` (or `from_user_id` when absent) per D2. A message with neither `from` nor `from_user_id`, or without `id`, is skipped.

| `type` | `Inbound` |
|---|---|
| `text`, trimmed body equals `Connect Ninjy` or starts with `Connect Ninjy` + whitespace (ASCII case-insensitive) | `kind=.Start`, `text` = remainder after the prefix, trimmed, lower-cased (`""` when none) |
| `text`, trimmed body lower-cased equals `disconnect` or `/disconnect` | `kind=.Disconnect`, `text=""` |
| `text`, otherwise | `kind=.Text`, `text = text.body` (untrimmed) |
| `reaction`, `system`, `edit`, `revoke`, `group` | skipped (no event) |
| any other type (`image`, `audio`, `video`, `document`, `sticker`, `location`, `contacts`, `interactive`, `button`, `order`, `unsupported`, unknown) | `kind=.Unsupported`, `text=""` |

Fields for every message event:

- `update_key = "whatsapp:" + phone_number_id + ":" + message.id`
- `external_chat_id = chat`, `external_user_id = user`, `external_message_id = message.id`
- `chat_is_private = true`
- `sender_display` = the matching `contacts[]` entry's `profile.name` (match on `user_id == user` or `wa_id == chat`); else its `profile.username`; else `"+" + chat` when `chat` is all digits; else `"WhatsApp user"`
- `provider_time` = `timestamp` parsed as decimal Unix seconds and formatted RFC 3339 UTC (`platform.format_rfc3339_utc`); zero value when it does not parse

**Statuses** (`value.statuses[]`): only `status == "failed"` produces an event; every other status is skipped.

- `kind=.Delivery_Failed`, `update_key = "whatsapp:" + phone_number_id + ":failed:" + status.id`
- `external_message_id = status.id`, `external_chat_id` = `recipient_id` when present, else `recipient_user_id`
- `provider_code = errors[0].code` (0 when `errors` is absent or empty), `provider_time` from `timestamp`, every other field empty

**`value.errors[]`** (system errors without messages or statuses) produce no event and are not logged by the hub; Meta shows them in its dashboard.

### 8.5 Error mapping

Applied in this order to a response:

| Response | `Channel_Error_Kind` | `retry_after_ms` |
|---|---|---|
| `cancel` set / httpc `.Aborted` | `.Aborted` | 0 |
| httpc transport error, `.Timeout`, HTTP 5xx | `.Transient` | 0 |
| `error.code == 131047` | `.Window_Closed` | 0 |
| `error.code` ∈ {132001, 132015, 132016} | `.Template_Unavailable` | 0 |
| `error.code == 131056` | `.Rate_Limited` | `WHATSAPP_PAIR_RATE_RETRY_MS` |
| `error.code == 130429`, or HTTP 429 | `.Rate_Limited` | `WHATSAPP_THROUGHPUT_RETRY_MS` |
| `error.code` ∈ {190, 368}, or HTTP 401 | `.Unauthorized` | 0 |
| `error.code` ∈ {131026, 131030} | `.Chat_Unavailable` | 0 |
| any other HTTP 4xx (including codes 100, 131009, 131062) | `.Invalid_Request` | 0 |
| HTTP 2xx without the expected result field (`messages[0].id`, `success:true`, `display_phone_number`) | `.Transient` | 0 |

`whatsapp_failure_kind(code)` applies the `error.code` rows of this table only (no HTTP status): 131047 → `.Window_Closed`; 132001, 132015, 132016 → `.Template_Unavailable`; 131056, 130429 → `.Rate_Limited`; 190, 368 → `.Unauthorized`; 131026, 131030 → `.Chat_Unavailable`; 0 → `.Transient`; any other code → `.Invalid_Request`. `whatsapp_request` uses the same proc for the code rows, so the two cannot disagree.

`provider_code` = `error.code` when present. `message` is a fixed string per proc: `"whatsapp request failed"`, `"whatsapp transport failed"`, `"whatsapp request aborted"`, `"invalid whatsapp response"`.

### 8.6 Fixtures (verbatim, from F6 and F9)

Text message (the W3 tests and the fake server use this shape; `display_phone_number`, ids and names are test values):

```json
{
  "object": "whatsapp_business_account",
  "entry": [{
    "id": "200000000000002",
    "changes": [{
      "field": "messages",
      "value": {
        "messaging_product": "whatsapp",
        "metadata": {"display_phone_number": "15550100001", "phone_number_id": "100000000000001"},
        "contacts": [{"profile": {"name": "Alice"}, "wa_id": "15551230001", "user_id": "US.13491208655302741918"}],
        "messages": [{
          "from": "15551230001",
          "from_user_id": "US.13491208655302741918",
          "id": "wamid.HBgLMTY1MDM4Nzk0MzkVAgASGBQzQTRBNjU5OUFFRTAzODEwMTQ0RgA=",
          "timestamp": "1763452800",
          "type": "text",
          "text": {"body": "hi"}
        }]
      }
    }]
  }]
}
```

Failed status (window closed):

```json
{
  "object": "whatsapp_business_account",
  "entry": [{
    "id": "200000000000002",
    "changes": [{
      "field": "messages",
      "value": {
        "messaging_product": "whatsapp",
        "metadata": {"display_phone_number": "15550100001", "phone_number_id": "100000000000001"},
        "statuses": [{
          "id": "wamid.HBgLMTY1MDM4Nzk0MzkVAgARGBI0QUQ2MjA4NEYyRkExNjMyREUA",
          "status": "failed",
          "timestamp": "1763539300",
          "recipient_id": "15551230001",
          "errors": [{"code": 131047, "title": "Re-engagement message", "message": "Re-engagement message",
                      "error_data": {"details": "Message failed to send because more than 24 hours have passed since the customer last replied to this number."}}]
        }]
      }
    }]
  }]
}
```

Graph error (window closed, synchronous form):

```json
{"error":{"message":"(#131047) Re-engagement message","type":"OAuthException","code":131047,"error_data":{"messaging_product":"whatsapp","details":"Message failed to send because more than 24 hours have passed since the customer last replied to this number."},"fbtrace_id":"AbCdEfGh"}}
```

## 9. Webhook route, push receive and intake (W5)

### 9.1 Route and handler

- **Paths:** `GET /api/v1/channels/whatsapp/webhook` and `POST /api/v1/channels/whatsapp/webhook`. The public callback URL is `<public hub origin>/api/v1/channels/whatsapp/webhook`; staging: `https://hub.mundus.in/api/v1/channels/whatsapp/webhook`.
- **File:** `src/hub/transport/http/bot_webhook_handlers.odin`.
- **Registration** in `src/hub/app/wiring.odin`, after the bots routes (`wiring.odin:822-834`):
  ```odin
  http.router_add(&graph.router, "GET", "/api/v1/channels/whatsapp/webhook", rawptr(&graph.bot_webhook_handlers), http.whatsapp_webhook_handler)
  http.router_add(&graph.router, "POST", "/api/v1/channels/whatsapp/webhook", rawptr(&graph.bot_webhook_handlers), http.whatsapp_webhook_handler)
  ```
- **No user authentication.** Like the Paddle webhook (`wiring.odin:700`, `src/hub/transport/http/billing_handlers.odin:65-71`), the handler MUST NOT call `require_auth`. The verify token (GET) and the signature (POST) are the authentication.

```odin
Bot_Webhook_Handlers :: struct {
	bots:          ^bots.Bots_Service,
	runtime:       ^bots.Bots_Runtime,
	trusted_cidrs: []string,              // config.forwarded_for_trusted_cidrs (as wired for device auth, wiring.odin:478)
	limiter:       Webhook_Rate_Limiter,
}

whatsapp_webhook_handler :: proc(ctx: rawptr, req: Request) -> Response // switches on req.method
```

The client IP is `device_auth.resolve_client_ip(req.remote_addr, header_value(req.headers, "X-Forwarded-For"), h.trusted_cidrs)` (`src/hub/service/device_auth/ip.odin:29`).

### 9.2 Constants (in `bot_webhook_handlers.odin`)

```odin
WHATSAPP_WEBHOOK_MAX_BODY_BYTES :: 4 << 20      // F5: payloads up to 3 MB
WHATSAPP_WEBHOOK_POST_PER_MINUTE :: 1200       // all callers together
WHATSAPP_WEBHOOK_GET_PER_MINUTE :: 120         // all callers together
WHATSAPP_WEBHOOK_BAD_SIGNATURE_PER_IP :: 20    // per client IP per window
WHATSAPP_WEBHOOK_CHALLENGE_MAX_BYTES :: 128
```

### 9.3 Rate limiter

```odin
Webhook_Rate_Limiter :: struct {
	mutex:          sync.Mutex,
	window_start_s: i64,                // fixed 60-second windows on the monotonic clock
	posts, gets:    int,
	bad_by_ip:      map[string]int,     // keys heap-owned; cleared and freed when a window starts
}
Webhook_Request_Kind :: enum { Get, Post }
// True when the request may proceed. A Post is refused while bad_by_ip[ip] >= WHATSAPP_WEBHOOK_BAD_SIGNATURE_PER_IP.
webhook_rate_admit :: proc(l: ^Webhook_Rate_Limiter, kind: Webhook_Request_Kind, ip: string, now_s: i64) -> bool
webhook_rate_note_bad_signature :: proc(l: ^Webhook_Rate_Limiter, ip: string, now_s: i64)
webhook_rate_destroy :: proc(l: ^Webhook_Rate_Limiter)
```

- A request admitted counts against its global budget (`posts` or `gets`) before any other check.
- `bad_by_ip` grows only on a bad signature of an admitted POST, so it holds at most `WHATSAPP_WEBHOOK_POST_PER_MINUTE` keys per window.
- An empty IP string counts under the key `"unknown"`.
- `now_s` comes from `time.tick_now()` converted to seconds; tests pass it directly.

### 9.4 Responses (verbatim rules, in order)

**GET**

| # | Condition | Response |
|---|---|---|
| 1 | `bots_push_enabled(h.bots, "whatsapp")` is false | 404 `not_found` |
| 2 | `webhook_rate_admit(.Get)` is false | 429 `rate_limited` |
| 3 | `hub.challenge` (decoded with `query_value`, `src/hub/transport/http/content_handlers.odin:612`) is empty, longer than `WHATSAPP_WEBHOOK_CHALLENGE_MAX_BYTES`, or has a byte outside `[0-9A-Za-z._-]` | 400 `validation_failed`, details `{"code":"challenge_invalid"}` |
| 4 | `bots_push_challenge(h.bots, "whatsapp", hub.mode, hub.verify_token)` is false | 403 `forbidden`, details `{"code":"verify_token_mismatch"}` |
| 5 | otherwise | `200`, `content_type = "text/plain"`, body = the challenge exactly |

**POST**

| # | Condition | Response |
|---|---|---|
| 1 | `bots_push_enabled` is false | 404 `not_found` |
| 2 | `webhook_rate_admit(.Post)` is false | 429 `rate_limited` |
| 3 | `len(req.body) > WHATSAPP_WEBHOOK_MAX_BODY_BYTES` | 400 `validation_failed`, details `{"code":"webhook_body_too_large"}` |
| 4 | `bots_push_receive` → `.Bad_Signature` | call `webhook_rate_note_bad_signature`; 401 `unauthenticated`, details `{"code":"webhook_signature_invalid"}` |
| 5 | → `.Bad_Payload` | 200 `{"received":true}` (a retry cannot fix it); log line in section 19 |
| 6 | → `.Store_Failed` | 503 `provider_unavailable`, details `{"code":"webhook_store_failed"}` (Meta retries, F3) |
| 7 | → `.Not_Configured` | 404 `not_found` |
| 8 | → `.Stored` | `bots_runtime_signal_intake(h.runtime)`; 200 `{"received":true}` |

- Error responses use `respond_error` with `bots.bots_detail_error` for details (as `bot_agent_handlers.odin:27`), so the body shape is the hub's standard error envelope.
- The signature header is read with `header_value(req.headers, "X-Hub-Signature-256")`, which matches names case-insensitively (`src/hub/transport/http/server.odin:239-244`).
- Rows 2 and 4 of POST, and every `.Bad_Payload`, print the matching section 19 line.
- The `200` body is JSON (`respond_success`), which Meta ignores.

### 9.5 Push receive (service)

**File:** `src/hub/service/bots/push.odin` (W5).

```odin
Push_Receive_Result :: enum { Stored, Bad_Signature, Bad_Payload, Store_Failed, Not_Configured }

// True when the provider's adapter supports push intake and at least one user has the bots experiment on.
// A repository error reads as false (fail closed).
bots_push_enabled :: proc(s: ^Bots_Service, provider: string) -> bool
bots_push_challenge :: proc(s: ^Bots_Service, provider, mode, verify_token: string) -> bool
bots_push_receive :: proc(s: ^Bots_Service, provider, signature, body: string) -> (result: Push_Receive_Result, events, inserted: int)
```

`bots_push_receive`:

1. `a := bots_adapter(s, provider)`; `a == nil || a.push_parse == nil` → `.Not_Configured`.
2. `batch, verdict := a.push_parse(a.ctx, signature, body, context.temp_allocator)`. `.Bad_Signature` and `.Bad_Payload` return as is.
3. Map each `Inbound` to a `domain.Channel_Push_Event`: `provider`, `event_key = update_key`, `kind` (same member name), `external_*`, `sender_display`, `body = text`, `provider_code`, `provider_time`, `received_at = now`.
4. Empty batch (statuses other than `failed`, reactions, foreign entries) → `.Stored` with `events = 0` and no database write.
5. `inserted, err := iface.push_events_insert(s.repo, events)`; error → `.Store_Failed`.
6. Log `bots: whatsapp webhook stored events=<n> new=<m>` and return `.Stored`.

No network I/O and no `Bots_Service.mutex` in this proc.

### 9.6 Intake thread

In `push.odin`:

```odin
BOT_PUSH_INTAKE_BATCH :: 50
BOT_PUSH_INTAKE_IDLE :: 5 * time.Second
BOT_PUSH_INTAKE_RETRY :: 5 * time.Second

bots_intake_entry :: proc(data: rawptr)            // like bots_poller_entry (runtime.odin:97-103)
bots_intake_thread :: proc(rt: ^Bots_Runtime)
// Returns more=true when a full batch was processed (loop again at once).
bots_push_intake_iteration :: proc(rt: ^Bots_Runtime) -> (more: bool, delay: time.Duration)
```

`bots_push_intake_iteration` (provider `"whatsapp"`, adapter `a = s.whatsapp`):

1. `events := push_events_pending("whatsapp", BOT_PUSH_INTAKE_BATCH)`. Error → `(false, BOT_PUSH_INTAKE_RETRY)`. None → `(false, BOT_PUSH_INTAKE_IDLE)`.
2. `now := platform.clock_now(s.clock)`. Build `[]channel.Inbound` from the events (strings borrowed from the event rows).
3. `rows := bots_inbound_rows(s, a, <inbound events whose kind is not .Delivery_Failed>, now)` (section 10.2).
4. **Touches.** For each event whose kind is not `.Delivery_Failed`: `binding := bots_find_binding(s, "whatsapp", chat, user)`; when found and `bots_gate_on(owner)`, append `{binding_id, at = provider_time if non-empty else now}`.
5. `inserted, err := push_batch_commit(rows, touches, <seq of every event>, now)`. Error → log `bots: whatsapp intake commit failed`, return `(false, BOT_PUSH_INTAKE_RETRY)`; nothing is marked processed, so the same events are retried.
6. For each distinct touched binding that had at least one `.Text` or `.Unsupported` event: `bots_release_held(s, binding_id)` (section 12.5).
7. For each event in `seq` order: `.Delivery_Failed` → `bots_on_delivery_failed(s, a, inbound)` (section 12.6); otherwise `bots_inbound_side_effect(s, a, inbound, now)` (section 10.2).
8. For each bot with a newly inserted row: `delivery_on_inbound(s, bot_id, now_ms)`, exactly as the poller (`poller.odin:65-73`).
9. Return `(len(events) == BOT_PUSH_INTAKE_BATCH, 0)`.

**Ordering.** Held replies (step 6) reach the user before any pairing reply or notice for the same batch, and before the bot is woken for the new message.

**Crash safety.** A crash before step 5 commits re-runs the batch. A crash after it loses at most the side effects of that batch, as for Telegram (slice 1 spec 9.3). Held replies are not lost: they stay `held` and the next message releases them.

### 9.7 Runtime (`runtime.odin`)

- Add to `Bots_Runtime` (`runtime.odin:11-22`): `intake: ^thread.Thread`, `intake_running, intake_stop, intake_signal: bool`.
- Replace the `poller: bool` parameter of `bots_runtime_stop_locked` (`runtime.odin:64`) with `worker: Bots_Worker`, `Bots_Worker :: enum { Poller, Supervisor, Intake }`, and update its callers.
- `bots_runtime_reconcile` (`runtime.odin:24-62`):
  - when `n == 0`: stop all three workers (the existing `bots: runtime stopped` line stays);
  - when `n > 0` and `rt.service.whatsapp != nil` and the intake is not running: start it with `bots_intake_entry` and the same `worker_context` as the poller, and print `bots: whatsapp intake started`;
  - when `rt.service.whatsapp == nil` and the intake runs: stop it and print `bots: whatsapp intake stopped`. Stopping because `n == 0` also prints this line.
- `bots_runtime_signal_intake :: proc(rt: ^Bots_Runtime)`: under `wait_mutex`, atomically set `intake_signal = true` and `cond_broadcast(&rt.wait_cond)`.
- `bots_intake_wait :: proc(rt: ^Bots_Runtime, delay: time.Duration) -> (stop: bool)`: like `bots_runtime_wait` (`runtime.odin:85-95`), but also returns when `intake_signal` is set, and clears it. The poller and supervisor ignore the extra broadcasts: their wait loop keeps its remaining budget.
- `bots_runtime_stop` stops the intake too.

### 9.8 Wiring (`wiring.odin`)

Next to the Telegram adapter (`wiring.odin:627-633`):

```odin
	configured, problem := app_whatsapp_config_state(config^)   // section 14.2
	if problem != "" do fmt.eprintln(problem)
	if configured {
		graph.whatsapp = channel.WhatsApp_Adapter{access_token = config.whatsapp_access_token, app_secret = config.whatsapp_app_secret,
			verify_token = config.whatsapp_verify_token, phone_number_id = config.whatsapp_phone_number_id,
			business_account_id = config.whatsapp_business_account_id, api_base = config.whatsapp_api_base}
		graph.whatsapp_adapter = channel.whatsapp_adapter(&graph.whatsapp)
		graph.bots.whatsapp = &graph.whatsapp_adapter
		fmt.printf("bots: whatsapp configured phone_number_id=%s\n", config.whatsapp_phone_number_id)
	}
	graph.bot_webhook_handlers = http.Bot_Webhook_Handlers{bots = &graph.bots, runtime = &graph.bots_runtime, trusted_cidrs = config.forwarded_for_trusted_cidrs}
```

- Graph fields: `whatsapp: channel.WhatsApp_Adapter`, `whatsapp_adapter: channel.Channel_Adapter`, `bot_webhook_handlers: http.Bot_Webhook_Handlers` next to `telegram` (`wiring.odin:104-105`).
- Teardown: `channel.whatsapp_destroy(&graph.whatsapp)` and `http.webhook_rate_destroy(&graph.bot_webhook_handlers.limiter)` next to `channel.telegram_destroy` (`wiring.odin:665`), after the runtime is stopped.
- `Bots_Service` gains `whatsapp: ^channel.Channel_Adapter` (nil when not configured) and `reengage_mutex: sync.Mutex` (section 12.4).

## 10. Provider-neutral bots service (W2)

### 10.1 Adapter lookup and binding lookup

In `src/hub/service/bots/service.odin`:

```odin
// Telegram keeps the existing field name `adapter` (wiring and tests set it).
bots_adapter :: proc(s: ^Bots_Service, provider: string) -> ^channel.Channel_Adapter {
	switch provider {
	case domain.CHANNEL_PROVIDER_TELEGRAM: return s.adapter
	case domain.CHANNEL_PROVIDER_WHATSAPP: return s.whatsapp
	}
	return nil
}

// Active binding for an inbound chat: by chat id first, then by user id (D2).
bots_find_binding :: proc(s: ^Bots_Service, provider, external_chat_id, external_user_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error)
```

`bots_find_binding` skips the second lookup when `external_user_id == ""`.

### 10.2 Signature changes

Every proc below takes the adapter (or provider) instead of assuming Telegram. Replace each `"telegram"` literal inside them with `a.provider` (or `provider`), and each `binding_get_active_by_chat` with `bots_find_binding`. Behaviour for Telegram is identical.

| Proc (file:line) | New signature |
|---|---|
| `bots_inbound_rows` (`inbound.odin:13`) | `(s: ^Bots_Service, a: ^channel.Channel_Adapter, batch: []channel.Inbound, now: string) -> ([]domain.Channel_Message, domain.Domain_Error)` |
| `bots_inbound_side_effect` (`inbound.odin:39`) | `(s, a: ^channel.Channel_Adapter, update: channel.Inbound, now: string) -> domain.Domain_Error` |
| `bots_pairing_start` (`pairing.odin:59`) | `(s, a: ^channel.Channel_Adapter, update: channel.Inbound, now: string) -> domain.Domain_Error` |
| `bots_pairing_apply` (`pairing.odin:69`) | `(s, a: ^channel.Channel_Adapter, update: channel.Inbound, now: string) -> (reply, previous_chat, owner, bot_id: string, err: domain.Domain_Error)` |
| `bots_notice` (`pairing.odin:52`) | `(s: ^Bots_Service, provider, chat_id, text: string)` |
| `bots_pairing_create` (`pairing.odin:25`) | `(s: ^Bots_Service, owner, provider: string) -> (Bot_Pairing_Link, domain.Domain_Error)` |
| `bots_disconnect` (`pairing.odin:129`) | `(s: ^Bots_Service, owner_user_id, provider: string, notify: bool) -> domain.Domain_Error` |
| `bots_disconnect_for_reason` (`pairing.odin:134`) | `(s, owner_user_id, provider: string, notify: bool, finish_reason: string) -> domain.Domain_Error` |
| `bots_disconnect_locked` (`pairing.odin:146`) | `(s, owner, provider, finish_reason: string) -> (domain.Channel_Binding, bool, domain.Domain_Error)` |
| `bots_queue_gave_up_locked` (`supervisor.odin:313`) | `(s: ^Bots_Service, owner, bot_id, through_message_id: string)` |

The poller passes `s.adapter` (`poller.odin:51`, `:63`).

**Inbound rules** (slice 1 spec 9.4, generalized; order unchanged):

| # | Condition | Store | Side effect |
|---|---|---|---|
| 1 | `!chat_is_private` | nothing | `bots_notice(provider, chat, COPY_PRIVATE_ONLY)` (never true for WhatsApp) |
| 2 | `kind == .Start` | nothing | pairing (10.4) |
| 3 | no binding from `bots_find_binding` | nothing | `bots_notice(provider, chat, copy.not_connected)` |
| 4 | binding owner has the experiment off | nothing | nothing |
| 5 | `kind == .Disconnect` | nothing | `bots_disconnect(owner, provider, notify=true)` |
| 6 | `kind == .Unsupported` | nothing | `bots_notice(provider, chat, COPY_UNSUPPORTED)` |
| 7 | `external_user_id != binding.external_user_id` | nothing | nothing |
| 8 | `kind == .Text` | inbound row (unchanged fields) | `delivery_on_inbound` after commit |

`copy = bots_channel_copy(a.provider)` (10.3). The 16 384-byte truncation (`inbound.odin:22-26`) applies to both providers.

### 10.3 Copy (`src/hub/service/bots/copy.odin`)

Existing constants stay unchanged (`copy.odin:3-14`). Add (verbatim):

```odin
COPY_WA_PAIRED :: "Connected to your Ninjy bot. WhatsApp's end-to-end encryption ends at Meta's business messaging service: Meta and your Ninjy hub can read messages in this chat. Anyone who can send messages from this WhatsApp account can instruct your bot, which runs commands on your machines. Send disconnect to disconnect."
COPY_WA_PAIR_INVALID :: "This connect code has expired or was already used. Open Settings > Bots in Ninjy and choose Connect WhatsApp to get a new one."
COPY_WA_CHAT_TAKEN :: "This WhatsApp account is already connected to another Ninjy account."
COPY_WA_NOT_CONNECTED :: "This WhatsApp account is not connected to Ninjy. Open Settings > Bots in Ninjy and choose Connect WhatsApp."
COPY_WA_REPLACED :: "This WhatsApp account was disconnected from Ninjy because another WhatsApp account was connected."

Bot_Channel_Copy :: struct { paired, pair_invalid, chat_taken, not_connected, replaced: string }

bots_channel_copy :: proc(provider: string) -> Bot_Channel_Copy {
	if provider == domain.CHANNEL_PROVIDER_WHATSAPP do return {COPY_WA_PAIRED, COPY_WA_PAIR_INVALID, COPY_WA_CHAT_TAKEN, COPY_WA_NOT_CONNECTED, COPY_WA_REPLACED}
	return {COPY_PAIRED, COPY_PAIR_INVALID, COPY_PAIR_CHAT_TAKEN, COPY_NOT_CONNECTED, COPY_REPLACED}
}
```

Shared by both providers, unchanged: `COPY_PAIR_NOT_ENABLED`, `COPY_PAIR_NO_BOT`, `COPY_UNSUPPORTED`, `COPY_DISCONNECTED`, `COPY_NO_MACHINE`, `COPY_GAVE_UP`, `COPY_PRIVATE_ONLY`.

REQ-WA-10 note: the copy table is keyed by the provider name; it holds text, not protocol. No Graph request, payload or error code appears outside `whatsapp.odin`.

### 10.4 Pairing

- `bots_pairing_create(s, owner, provider)`: `a := bots_adapter(s, provider)`; nil → `domain_error(.Provider_Unavailable, "<provider> is not configured on this hub", {"code":"channel_not_configured"})`. `pairing_delete_for_owner` and `pairing_insert` use `provider`. Otherwise identical (`pairing.odin:25-44`).
- `Bot_Pairing_Link` (`pairing.odin:23`) gains `pairing_text: string` = `a.pairing_text(a.ctx, code)` when that proc is non-nil, else `""` (Telegram). The bots service never builds the text itself. The Telegram route keeps returning only `pairing_url` and `expires_at` (15.1).
- `bots_pairing_apply` runs the slice 1 table (spec 9.6) with `copy` for the provider. Row 7's new binding sets `last_inbound_at = update.provider_time` when non-empty, else `now`, and `external_display = update.sender_display`.
- A duplicate WhatsApp pairing message never reaches the rules: the push queue dropped it (D1).

### 10.5 Disconnect

- `DELETE /api/v1/bots/me/channels/whatsapp` → `bots_disconnect(owner, "whatsapp", notify=true)`; `disconnect` in the chat → same.
- It revokes only that provider's binding. A connected Telegram chat stays connected.
- `bots_delete` (`service.odin:157`) calls `bots_disconnect_for_reason(s, owner, p, true, "bot_deleted")` for `p` in `{"telegram", "whatsapp"}`, ignoring `.Not_Found` for each, and `pairing_delete_for_owner` for both providers (replacing the single Telegram call at `service.odin:216`).
- A disconnect purges the binding's messages (`messages_purge_binding`), which also expires its held rows (6.3).

### 10.6 Hub notices go to the origin channel

- `Bot_Notice` (`supervisor.odin:16`) becomes `struct {owner, bot_id, through_message_id, text: string}`. Every queueing site passes the delivery's `bot_id` and `through_message_id` (`supervisor.odin:293`, `:313-316`).
- Sending (`supervisor.odin:301-305`): `binding := bots_notice_binding(s, owner, bot_id, through_message_id)`, then `bots_notice(s, binding.provider, binding.external_chat_id, text)`.
- `bots_notice_binding` (in `routing.odin`, 11.1): the binding of the inbound message `through_message_id` when that binding is active; otherwise `bots_reply_binding`.
- A notice to a WhatsApp chat whose window is closed is not sent and not held (12.3 step 4): notices are not replies.

## 11. Reply routing (U1) (W4; `bots_reply_binding` and `bots_notice_binding` are written in W2)

### 11.1 Rules (`src/hub/service/bots/routing.odin`)

```odin
// The channel whose messages `channel read` returns.
bots_read_binding :: proc(s: ^Bots_Service, owner, bot_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error)
// The channel `channel send` answers.
bots_reply_binding :: proc(s: ^Bots_Service, owner, bot_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error)
bots_notice_binding :: proc(s: ^Bots_Service, owner, bot_id, through_message_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error)
```

Let `A = bindings_active_for_owner(owner)` (Telegram first, then WhatsApp). "Eligible row" = `direction == .Inbound && !body_purged && binding_id ∈ A`.

**`bots_read_binding`**, first match wins:

1. `A` empty → not found.
2. The binding of the first eligible row of `messages_pending(bot_id, -1)` (oldest first).
3. `A[0]`.

**`bots_reply_binding`**, first match wins:

1. `A` empty → not found.
2. The binding of the first eligible row of `messages_pending(bot_id, -1)` with `read_at != ""` (the oldest read, unanswered message).
3. The binding of the first eligible row of `messages_history(bot_id, -1)` (newest first).
4. `A[0]`.

These rules are the only place a reply target is chosen. `ham-ctl channel send` has no channel argument.

### 11.2 `channel read`

- `bot_channel_require` (`bot_agent_handlers.odin:18-36`) no longer looks up a Telegram binding. It returns the bot when `bindings_active_for_owner` is non-empty, else 409 `conflict` `{"code":"channel_not_paired"}` (same code as today).
- The read handler calls `binding := bots_read_binding(...)`, then `bots_channel_read(h.bots, bot.bot_id, binding, limit)` (`feedback.odin:19`).
- In `bots_channel_read`, `pending_total` counts every pending inbound row of the bot that is not purged, whatever its binding. Selection and marking stay limited to `binding` (`feedback.odin:38-53`).
- Wire: `Bot_Channel_Read_Message` (`bot_agent_handlers.odin:9`) gains `channel: string` = `binding.provider`.

```text
$ ./bin/ham-ctl channel read
{"v":1,"ok":true,"data":{"messages":[{"message_id":"chm_18e9100000000001","body":"hi","created_at":"2026-11-18T09:00:00Z","sender":"Alice","channel":"whatsapp"}],"pending_total":2}}
```

### 11.3 `channel send`

- The send handler (`bot_agent_handlers.odin:66-82`) calls `binding := bots_reply_binding(...)`, then `ids, held, err := channel_send(h.bots, binding, text, true)` (12.3), then `bots_channel_replied(h.bots, bot.bot_id, binding.binding_id)`.
- `bots_channel_replied` (`inbound.odin:92`) takes `binding_id` and calls `messages_mark_replied_binding` instead of `messages_mark_replied` (`inbound.odin:98`). The delivery check after it is unchanged.
- Response `data`: `{"message_ids":["chm_…"],"chunks":1,"channel":"whatsapp","held":false}`. A held reply is a success (HTTP 200, `"held":true`).

### 11.4 `channel history`

The handler (`bot_agent_handlers.odin:84-101`) adds `channel` to each row: the provider of the row's binding when the binding is in `A`. Rows whose binding is not active are omitted (their bodies are purged anyway). Example row: `{"message_id":"chm_…","direction":"outbound","body":"echo: hi","created_at":"…","channel":"whatsapp"}`.

### 11.5 `ham-ctl` help (`src/ctl/channel_cmds.odin:8-12`, `src/ctl/agent_mode.odin:1878`)

`CHANNEL_HELP` becomes (verbatim):

```text
ham-ctl channel read [--limit N]        Read your owner's unanswered messages from one channel (marks them read).
ham-ctl channel send --text <text>      Answer on the channel of the messages you read.
ham-ctl channel send --text-file <path> Same, text read from a UTF-8 file.
ham-ctl channel history [--limit N]     Recent messages on all channels in both directions, newest first.
Only a bot instance may use these verbs. Telegram and WhatsApp messages can be read by the provider and your Ninjy hub.
```

The agent help line at `agent_mode.odin:1878` becomes `  channel     Read and answer Telegram and WhatsApp messages (bot only)`. No argument changes.

### 11.6 Bot template (`src/templates/bot.md`)

Lines 3, 6, 7, 9 and 18 change and two lines are added. The result of these lines is (verbatim):

```markdown
You are the user's personal Ninjy bot. The user talks to you from Telegram or WhatsApp.

## How messages reach you
- A line "New Telegram message for you" means the user wrote to you on Telegram or WhatsApp. Run `./bin/ham-ctl channel read` to get the unanswered messages of one channel; each message has a `channel` field.
- Answer with `./bin/ham-ctl channel send --text "<answer>"`. Your answer goes to the channel of the messages you read. Send one answer that covers all messages you read. Plain text only; links are fine.
- If `pending_total` is larger than the number of messages you read, more messages are waiting: after answering, run `./bin/ham-ctl channel read` again and answer those too.
- If the send result says `"held":true`, WhatsApp's 24-hour reply window had closed. Your answer is saved and reaches the user when they next write. Do not send it again.
- After a fresh start, run `./bin/ham-ctl channel history --limit 20` once to see the recent conversation.
- Never use `ham-ctl chat send` to answer channel messages.
```

and line 18 becomes:

```markdown
- Telegram and WhatsApp messages can be read by the provider and the Ninjy hub: do not send secrets, tokens or file contents that look sensitive.
```

The capabilities track (`docs/plans/bots-capabilities-spec.md`, task `task_18e908df7921d5e8`) also edits this file, in the "What you can do" and "What you must not do" sections. W5 MUST NOT touch any other line. On a merge conflict, keep both changes.

## 12. The 24-hour window (U2) (W4)

### 12.1 Stamping

`channel_bindings.last_inbound_at` is set by `push_batch_commit` touches (9.6 step 4) and by pairing (10.4). Any message from the user counts (text, unsupported, disconnect), because any user message opens WhatsApp's customer service window. The touch also clears `reengage_sent_at` and `reengage_error`. Telegram bindings are never touched (they have no push path) and Telegram has no window.

### 12.2 Window check

In `src/hub/service/bots/window.odin`. W2 creates the file with this proc and constant, because the bot view (15.2) needs them; W4 adds the rest of section 12 to the same file.

```odin
BOT_REPLY_WINDOW_MARGIN_MS :: 600_000 // hold 10 minutes early: replies near the edge are kept, not lost

bots_window_closed :: proc(a: ^channel.Channel_Adapter, binding: domain.Channel_Binding, now_ms: i64) -> bool {
	if a == nil || a.reply_window_ms <= 0 do return false
	last, ok := platform.rfc3339_to_unix_ms(binding.last_inbound_at)
	if !ok do return true
	return now_ms >= last + a.reply_window_ms - BOT_REPLY_WINDOW_MARGIN_MS
}
```

### 12.3 `channel_send` (`channel_send.odin:35`)

New signature:

```odin
channel_send :: proc(s: ^Bots_Service, binding: domain.Channel_Binding, text: string, record: bool) -> (message_ids: []string, held: bool, err: domain.Domain_Error)
```

1. `a := bots_adapter(s, binding.provider)`; nil → `domain_error(.Provider_Unavailable, "<provider> is not configured on this hub", {"code":"channel_not_configured"})`.
2. UTF-8 check and chunking: unchanged (`channel_send.odin:37-40`).
3. `closed := bots_window_closed(a, binding, now_ms)`.
4. `!record && closed` → return `nil, false, domain_error(.Provider_Unavailable, "channel send failed", {"code":"channel_send_failed","kind":"Window_Closed"})` without a provider call.
5. `record`: insert one outbound row per chunk, `send_state = .Held` when `closed`, else `.Pending` (`channel_send.odin:42-61`).
6. `record && closed` → log `bots: reply held binding=<binding_id> chunks=<n>`, call `bots_reengage(s, binding.binding_id)` (12.4), return `ids, true, {}`.
7. Send loop: unchanged retry policy, moved into `bots_send_chunk :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, chat_id, text: string) -> (external_message_id: string, err: channel.Channel_Error)` so 12.5 reuses it.
8. A chunk failing with `.Window_Closed` when `record`: set that row and every later row to `.Held` (`message_set_send_result(id, .Held, "", "")`), log the held line, call `bots_reengage`, return `ids, true, {}`. Without `record`, `.Window_Closed` is a failure like any other kind (`channel_send.odin:94-101`).
9. Everything else unchanged.

Callers: `bots_notice` discards `held`; the send handler returns it (11.3).

### 12.4 Re-engagement template

**Template the operator creates in WhatsApp Manager (verbatim):**

| Field | Value |
|---|---|
| Name | `ninjy_reply_waiting` |
| Category | Utility |
| Language | English (`en`) |
| Header | none |
| Body | `Your Ninjy bot has finished its reply to your last message. Reply here to receive it.` |
| Footer | none |
| Buttons | none |
| Variables | none |

The body names the user's own earlier message, which keeps it a utility message (F18).

**`bots_reengage :: proc(s: ^Bots_Service, binding_id: string)`** (in `window.odin`), under `s.reengage_mutex`, never under `s.mutex`, outside any transaction:

1. `binding := binding_get(binding_id)`; not found or not active → return.
2. `binding.reengage_sent_at != ""` → return (one template per closed window; 12.1 clears it when the user writes).
3. `a := bots_adapter(s, binding.provider)`; `a == nil || a.send_reengage == nil` → return.
4. `!bots_gate_on(s.experiments, binding.owner_user_id)` → return.
5. `id, err := a.send_reengage(a.ctx, binding.external_chat_id)`; free `id`.
6. Result:

| `err.kind` | Write | Log |
|---|---|---|
| `.None` | `binding_set_reengage(binding_id, now, "")` | `bots: reengage sent binding=<binding_id>` |
| `.Template_Unavailable` | `binding_set_reengage(binding_id, "", "template_unavailable")` | `bots: reengage failed binding=<binding_id> kind=Template_Unavailable code=<n>` |
| any other | `binding_set_reengage(binding_id, "", "send_failed")` | `bots: reengage failed binding=<binding_id> kind=<kind> code=<n>` |

7. `bots_publish_changed(s, owner, bot_id)` so Settings refreshes.

**While the template is not approved** (`132001`, F17): every held reply tries the template once (step 2 lets it, because `reengage_sent_at` stays empty), records `template_unavailable`, and keeps the reply held. Nothing retries on a timer. The UI says the reminder could not be sent (16.2). The held reply is delivered when the user writes, whether or not a template was ever sent.

### 12.5 Releasing held replies

**`bots_release_held :: proc(s: ^Bots_Service, binding_id: string)`** (in `window.odin`), called by the intake (9.6 step 6) after the commit, outside `s.mutex`:

1. `binding := binding_get(binding_id)`; not found, not active, or owner gate off → return.
2. `a := bots_adapter(s, binding.provider)`; `bots_window_closed(a, binding, now)` → return.
3. `rows := messages_held(binding_id)` (oldest first, purged rows excluded).
4. For each row, `bots_send_chunk(s, a, binding.external_chat_id, row.body)`:
   - success → `message_set_send_result(row.message_id, .Sent, external_id, "")`;
   - `.Window_Closed` → stop; this row and later rows stay held;
   - any other kind → `message_set_send_result(row.message_id, .Failed, "", "<kind name>")` and continue.
5. Log `bots: held released binding=<binding_id> sent=<n> failed=<m> kept=<k>`; when `n + m > 0`, `bots_publish_changed`.

Released rows keep their `created_at`; the bot sees them in `channel history` as outbound rows in their original order.

### 12.6 Asynchronous window failures (F15)

**`bots_on_delivery_failed :: proc(s: ^Bots_Service, a: ^channel.Channel_Adapter, update: channel.Inbound)`** (in `window.odin`):

1. `binding := bots_find_binding(s, a.provider, update.external_chat_id, "")`; not found → return.
2. `msg := message_get_outbound_by_external(binding.binding_id, update.external_message_id)`; not found, or `msg.send_state != .Sent` → return.
3. `kind := a.failure_kind(update.provider_code)` (`.Invalid_Request` when `failure_kind` is nil).
4. `kind == .Window_Closed` → `message_set_send_result(msg.message_id, .Held, "", "")`, log `bots: reply held binding=<binding_id> chunks=1`, `bots_reengage(s, binding.binding_id)`.
5. Otherwise → `message_set_send_result(msg.message_id, .Failed, msg.external_message_id, "<kind name>")`.

Hub notices are not recorded, so their failures find no row and are ignored.

### 12.7 Expiry

Held rows older than the 30-day retention (`bot_channel_retention_ms`) are purged with the other bodies and become `failed`/`held_expired` (6.3). The supervisor's hourly retention pass (`supervisor.odin:298-310`) also calls `push_events_purge_processed(now - 7 days)`.

## 13. Read feedback (W4)

`bots_channel_read` (`feedback.odin:55-66`) becomes, after the mark-read commit and with the same gate check:

1. `a := bots_adapter(s, binding.provider)`; nil → skip feedback.
2. `started := time.tick_now()`.
3. When `a.mark_read != nil`: one call for the **newest** newly-read message (`newly_read` is oldest first, so its last element). WhatsApp marks earlier messages read with it (F11). On error, log `bots: mark read failed kind=<kind>`; when the kind is `.Transient`, `.Aborted` or `.Rate_Limited`, skip step 4.
4. When `a.react != nil`: the existing loop (`feedback.odin:58-65`), with the same `started`, so mark-read and reactions share `BOT_READ_REACTION_BUDGET` (4 s).

WhatsApp bounds each call to `WHATSAPP_FEEDBACK_TIMEOUT_MS` (1 s), so feedback adds at most about 5 s to a read, as for Telegram (`feedback.odin:11-14`). Feedback never fails a read. Telegram's `mark_read` is nil, so Telegram behaves exactly as before.

## 14. Configuration (W1: fields, parsing, validation; W5: wiring and `SELF_HOSTING.md`)

### 14.1 Keys

`Hub_Config` (`src/hub/app/config_bind.odin:9-13`) gains, after `telegram_api_base`:

```odin
whatsapp_access_token:        string, // secret; never logged
whatsapp_app_secret:          string, // secret; never logged
whatsapp_verify_token:        string, // secret; never logged
whatsapp_phone_number_id:     string,
whatsapp_business_account_id: string,
whatsapp_api_base:            string, // default "https://graph.facebook.com"
```

The default for `whatsapp_api_base` goes next to `telegram_api_base = "https://api.telegram.org"` (`config_bind.odin:146`).

| Field | Inline env | File env (used when the inline env is empty) | Flag (wins over env) |
|---|---|---|---|
| `whatsapp_access_token` | `HEIMDALL_WHATSAPP_ACCESS_TOKEN` | `HEIMDALL_WHATSAPP_ACCESS_TOKEN_FILE` | `--whatsapp-access-token-file <path>` |
| `whatsapp_app_secret` | `HEIMDALL_WHATSAPP_APP_SECRET` | `HEIMDALL_WHATSAPP_APP_SECRET_FILE` | `--whatsapp-app-secret-file <path>` |
| `whatsapp_verify_token` | `HEIMDALL_WHATSAPP_VERIFY_TOKEN` | `HEIMDALL_WHATSAPP_VERIFY_TOKEN_FILE` | `--whatsapp-verify-token-file <path>` |
| `whatsapp_phone_number_id` | `HEIMDALL_WHATSAPP_PHONE_NUMBER_ID` | `HEIMDALL_WHATSAPP_PHONE_NUMBER_ID_FILE` | `--whatsapp-phone-number-id <id>` |
| `whatsapp_business_account_id` | `HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID` | `HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID_FILE` | `--whatsapp-business-account-id <id>` |
| `whatsapp_api_base` | `HEIMDALL_WHATSAPP_API_BASE` | — | `--whatsapp-api-base <url>` |

- **Code:** `apply_whatsapp_env :: proc(config: ^app.Hub_Config)` in `src/hub/main.odin`, called from `parse_args` right after `apply_telegram_env(config)` (`main.odin:154`), written like `apply_telegram_env` (`main.odin:451-457`). File values go through `read_key_file` (`main.odin:407`), which trims. Flags go in the flag loop next to `--telegram-bot-token-file` (`main.odin:192-195`).
- No value is ever printed, except `whatsapp_phone_number_id` in the startup line of 9.8 (it is an identifier, not a secret).

### 14.2 Validation

In `config_bind.odin` (W1):

```odin
// configured=true only when all five values are usable. problem is "" or one log line.
app_whatsapp_config_state :: proc(config: Hub_Config) -> (configured: bool, problem: string)
```

| Condition | `configured` | `problem` (verbatim) |
|---|---|---|
| all five of access token, app secret, verify token, phone number id, business account id empty | false | `""` |
| some but not all five set | false | `bots: whatsapp disabled: missing <names>`, `<names>` = the inline env names of the empty ones, comma-separated, in table order |
| phone number id or business account id not all ASCII digits | false | `bots: whatsapp disabled: phone number id and business account id must be digits` |
| verify token shorter than 16 bytes | false | `bots: whatsapp disabled: verify token must be at least 16 characters` |
| otherwise | true | `""` |

The hub starts in every case; WhatsApp simply stays off.

### 14.3 `SELF_HOSTING.md` (verbatim, a new section after "Telegram bot configuration", `SELF_HOSTING.md:1422-1437`)

```markdown
### WhatsApp bot configuration

Bots remain off until a user enables the `bots` experiment. WhatsApp uses Meta's
WhatsApp Cloud API and needs five values from your Meta app:

| Value | Environment variable | File variant | Flag |
|---|---|---|---|
| System-user access token | `HEIMDALL_WHATSAPP_ACCESS_TOKEN` | `HEIMDALL_WHATSAPP_ACCESS_TOKEN_FILE` | `--whatsapp-access-token-file` |
| App secret | `HEIMDALL_WHATSAPP_APP_SECRET` | `HEIMDALL_WHATSAPP_APP_SECRET_FILE` | `--whatsapp-app-secret-file` |
| Webhook verify token (16+ characters you choose) | `HEIMDALL_WHATSAPP_VERIFY_TOKEN` | `HEIMDALL_WHATSAPP_VERIFY_TOKEN_FILE` | `--whatsapp-verify-token-file` |
| Phone number ID | `HEIMDALL_WHATSAPP_PHONE_NUMBER_ID` | `HEIMDALL_WHATSAPP_PHONE_NUMBER_ID_FILE` | `--whatsapp-phone-number-id` |
| WhatsApp Business Account ID | `HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID` | `HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID_FILE` | `--whatsapp-business-account-id` |

An inline variable wins over its file variant; a flag wins over both. File
contents are trimmed. The token, app secret and verify token are secrets and are
never logged. If only some values are set, the hub starts with WhatsApp disabled
and logs which variables are missing.

**Public URL required.** Meta delivers messages by calling your hub. The hub must
be reachable from the internet over HTTPS with a certificate from a public
authority (self-signed certificates are refused) at
`https://<your hub>/api/v1/channels/whatsapp/webhook`. A hub behind NAT needs a
reverse proxy or tunnel that forwards this path. The endpoint answers `404` until
WhatsApp is configured and at least one user has enabled the `bots` experiment,
so enable the experiment before you verify the webhook in Meta.

In the Meta app dashboard, set the callback URL to that address, set the verify
token to the same value as `HEIMDALL_WHATSAPP_VERIFY_TOKEN`, and subscribe to the
`messages` field. Create the message template `ninjy_reply_waiting` (category
Utility, language English `en`, body "Your Ninjy bot has finished its reply to your
last message. Reply here to receive it.", no variables or buttons). Until Meta
approves it, replies written more than 24 hours after a user's last message are
kept and shown in Settings > Bots, and delivered when the user writes again.

`HEIMDALL_WHATSAPP_API_BASE` overrides the default `https://graph.facebook.com`
(tests point it at a fake server); `--whatsapp-api-base <url>` overrides that.
```

## 15. User API and bot view (W2)

### 15.1 Routes

| Method & path | Body | Success | Specific errors |
|---|---|---|---|
| `POST /api/v1/bots/me/channels/whatsapp/pairing` | `{}` | 201 `{"pairing_url":"https://wa.me/15550100001?text=Connect%20Ninjy%203f2a…","pairing_text":"Connect Ninjy 3f2a…","phone_display":"+15550100001","expires_at":"2026-11-18T09:10:00Z"}` | 503 `provider_unavailable` `{"code":"channel_not_configured"}`; 503 `provider_unavailable` when the identity lookup fails |
| `DELETE /api/v1/bots/me/channels/whatsapp` | — | 200 `{"disconnected":true}` | 404 `not_found` `{"code":"binding_not_found"}` |

- Handlers `bot_whatsapp_pairing_handler` and `bot_whatsapp_disconnect_handler` in `src/hub/transport/http/bot_handlers.odin`, registered next to the Telegram routes (`wiring.odin:829-830`). Auth and experiment checks as every bots route (`bot_require_auth`, `bot_handlers.odin:21`).
- `phone_display = "+" + identity.bot_username`.
- The Telegram handlers (`bot_handlers.odin:171-190`) pass `"telegram"` to the generalized procs and keep their exact responses (`{"pairing_url","expires_at"}`).
- `GET /api/v1/bots/me/channels/telegram/messages` stays as is; it already returns the bot's whole history, both channels.

### 15.2 Bot view

`Bot_View` (`service.odin:79-84`) gains `whatsapp: Bot_WhatsApp_View`; the `telegram` block is unchanged.

```json
"whatsapp": {
  "configured": true,
  "phone_display": "+15550100001",
  "binding": {"state": "active", "display": "Alice", "connected_at": "2026-11-18T09:00:00Z"},
  "window_open": false,
  "reengage_sent": false,
  "reengage_error": "template_unavailable",
  "held_replies": [{"message_id": "chm_18e9100000000009", "body": "echo: late?", "created_at": "2026-11-19T10:00:00Z"}]
}
```

- `configured` = `s.whatsapp != nil`. `phone_display` = `"+" + identity.bot_username` when the identity call succeeds, else `""`.
- `binding` is `null` without an active WhatsApp binding; then `window_open=false`, `reengage_sent=false`, `reengage_error=""`, `held_replies=[]`.
- `window_open = !bots_window_closed(adapter, binding, now)`; `reengage_sent = binding.reengage_sent_at != ""`; `reengage_error = binding.reengage_error`.
- `held_replies`: `messages_held(binding_id)`, oldest first, at most 20.

TypeScript (`src/ui/api/endpoints/bots.ts`):

```ts
export interface BotWhatsApp {
  configured: boolean;
  phone_display: string;
  binding: null | { state: string; display: string; connected_at: string };
  window_open: boolean;
  reengage_sent: boolean;
  reengage_error: '' | 'template_unavailable' | 'send_failed';
  held_replies: { message_id: string; body: string; created_at: string }[];
}
// BotView gains: whatsapp: BotWhatsApp;
export interface WhatsAppPairing { pairing_url: string; pairing_text: string; phone_display: string; expires_at: string }
// endpoints:
createWhatsAppPairing: build.mutation<WhatsAppPairing, void>({ queryFn: () => request(root + '/channels/whatsapp/pairing', 'POST', {}), invalidatesTags: ['Bot'] }),
disconnectWhatsApp: build.mutation<{ disconnected: boolean }, void>({ queryFn: () => request(root + '/channels/whatsapp', 'DELETE'), invalidatesTags: ['Bot'] }),
// exported hooks: useCreateWhatsAppPairingMutation, useDisconnectWhatsAppMutation
```

`BotMessage.send_state` (`bots.ts:18`) can now be `"held"`.

## 16. Settings > Bots: WhatsApp card (W6)

### 16.1 Structure

- **New file** `src/ui/components/settings/BotWhatsAppCard.tsx`, built like `BotTelegramCard.tsx` (after `6fb3748e`): `@ui` components only (`Alert`, `Button`, `Link`, `Modal`, `Panel`, `Text`), a `pending` ref against double submits, `loading` on the button that runs, `disabled` on the others.
- `BotsPanel.tsx` renders `<BotWhatsAppCard key={bot.bot_id + '-whatsapp'} whatsapp={bot.whatsapp} />` right after the Telegram card (`BotsPanel.tsx:50`).
- **QR code:** dependency `qrcode-generator` pinned to exactly `1.4.4` (`npm install --save-exact qrcode-generator@1.4.4`; update `package-lock.json` and `npmDepsHash` in `flake.nix:27`). Helper in `src/ui/components/settings/botsView.ts`:
  ```ts
  import qrcode from 'qrcode-generator';
  export function whatsAppQrDataUrl(url: string): string {
    const qr = qrcode(0, 'M');
    qr.addData(url);
    qr.make();
    return qr.createDataURL(4, 8);
  }
  ```
  The card renders `<img src={whatsAppQrDataUrl(link.pairing_url)} alt="QR code to connect WhatsApp" className="h-48 w-48" data-debug-id="settings-bots-whatsapp-qr" />`. **Assumption A9** (verify in W6): the package ships its TypeScript declarations. If not, W6 adds `src/ui/types/qrcode-generator.d.ts` declaring exactly the four calls above.
- Pure helper `whatsAppCardState(w: BotWhatsApp): 'unconfigured' | 'unpaired' | 'paired' | 'held'` in `botsView.ts`: `!configured` → `unconfigured`; `binding === null` → `unpaired`; `held_replies.length > 0` → `held`; else `paired`.

### 16.2 Copy and `data-debug-id`s (verbatim; register every id in `docs/ui-debug-ids.md`)

| Element | Copy | `data-debug-id` |
|---|---|---|
| card (Panel title "WhatsApp") | — | `settings-bots-whatsapp-card` |
| not configured | "WhatsApp is not set up on this Ninjy hub. Ask your hub operator to connect a WhatsApp Business number." | `settings-bots-whatsapp-unconfigured` |
| unpaired | "Connect your WhatsApp to talk to your bot." | `settings-bots-whatsapp-unpaired` |
| connect button | "Connect WhatsApp" | `settings-bots-whatsapp-connect-btn` |
| link block | "Open this link on your phone within 10 minutes, or scan the code with your phone's camera. Send the prefilled message without changing it:" + the link (`Link`, opens in a new tab) + the QR image + "Copy link" button + the line "Message: {pairing_text}" | `settings-bots-whatsapp-link`, `settings-bots-whatsapp-open-link`, `settings-bots-whatsapp-qr`, `settings-bots-whatsapp-copy-btn`, `settings-bots-whatsapp-pairing-text` |
| paired | "Connected to {display}" | `settings-bots-whatsapp-paired` |
| disconnect button | "Disconnect" (confirm dialog title "Disconnect WhatsApp?", body "Disconnect WhatsApp? Your bot will stop receiving messages from this WhatsApp account.", buttons "Cancel" / "Disconnect") | `settings-bots-whatsapp-disconnect-btn`, `settings-bots-whatsapp-disconnect-dialog`, `settings-bots-whatsapp-disconnect-cancel-btn`, `settings-bots-whatsapp-disconnect-confirm-btn` |
| held replies (state `held`; `Alert tone="warning"`) | "Your bot answered after WhatsApp's 24-hour reply window closed. Send any WhatsApp message to your bot to receive the reply." followed by each held body in a `Text` with `whitespace-pre-wrap` | `settings-bots-whatsapp-held`, `settings-bots-whatsapp-held-item-{index}` |
| reminder line under the held alert | `reengage_sent` → "Ninjy sent you a WhatsApp reminder."; `reengage_error === 'template_unavailable'` → "Ninjy could not send you a WhatsApp reminder because its message template is not approved yet."; `reengage_error === 'send_failed'` → "Ninjy could not send you a WhatsApp reminder."; otherwise nothing | `settings-bots-whatsapp-reminder` |
| encryption notice (always shown) | "WhatsApp's end-to-end encryption ends at Meta's business messaging service. Meta and your Ninjy hub can read these messages. Anyone who can send messages from your WhatsApp account can instruct your bot, which runs commands on your machines." | `settings-bots-whatsapp-notice` |
| error | `apiErrorText(e)` in `Alert tone="danger"` | — |

**Copy updates elsewhere (verbatim):**

| Place | Old | New |
|---|---|---|
| empty state (`BotsPanel.tsx:43`) | "You don't have a bot yet. Your bot runs on your machines and answers you on Telegram." | "You don't have a bot yet. Your bot runs on your machines and answers you on Telegram or WhatsApp." |
| delete dialog (`BotsPanel.tsx:54`) | "Delete your bot? Its Telegram connection and Telegram message history are removed." | "Delete your bot? Its Telegram and WhatsApp connections and message history are removed." |
| Settings category description (`SettingsModal.tsx:85`) | "Your personal bot on Telegram." | "Your personal bot on Telegram and WhatsApp." |
| experiment description (`experimentFlags.ts:60`) | "A personal bot you can talk to from Telegram. It runs on your machines; Ninjy picks the machine and model." | "A personal bot you can talk to from Telegram or WhatsApp. It runs on your machines; Ninjy picks the machine and model." |

The bot view is already polled every 10 s while the panel is open (`BotsPanel.tsx:15`) and refreshed by `bot_changed`, so held replies and reminder state appear without new wiring.

## 17. Fake WhatsApp server (W3)

**Files:** `tools/fake_whatsapp/server.mjs`, `tools/fake_whatsapp/server_test.mjs`, `tools/fake_whatsapp/README.md`. Node 20, no dependencies, loopback only. Same shape as `tools/fake_telegram/server.mjs`: it exports a factory that returns an unstarted `http.Server` (`fake_telegram/server.mjs:4`, `:105`) and has a CLI entry point with `--port 0 --ready-file <path>` (`fake_telegram/server.mjs:108-116`).

```js
export function createFakeWhatsApp({
  accessToken = 'TEST-WA-TOKEN', appSecret = 'test-app-secret', verifyToken = 'test-verify-token-0001',
  phoneNumberId = '100000000000001', businessAccountId = '200000000000002', displayPhone = '15550100001',
  webhookUrl = '',
} = {}) // returns http.Server
```

```text
node tools/fake_whatsapp/server.mjs --port 18098 --access-token TEST-WA-TOKEN --app-secret test-app-secret \
  --verify-token test-verify-token-0001 --phone-number-id 100000000000001 --business-account-id 200000000000002 \
  --display-phone 15550100001 --webhook-url http://127.0.0.1:18181/api/v1/channels/whatsapp/webhook [--ready-file <path>]
```

### 17.1 Graph endpoints

Any path prefix `/v<major>.<minor>/` is accepted and recorded (so tests can assert `v27.0`).

| Request | Behaviour |
|---|---|
| any Graph request whose `Authorization` is not `Bearer <accessToken>` | 401 `{"error":{"message":"Invalid OAuth access token.","type":"OAuthException","code":190,"fbtrace_id":"fake"}}` |
| `GET /<v>/<phoneNumberId>?fields=…` | 200 `{"display_phone_number":"<displayPhone>","verified_name":"Ninjy Test","id":"<phoneNumberId>"}` |
| `POST /<v>/<other id>/messages` | 400 error code 100 |
| `POST /<v>/<phoneNumberId>/messages` with `status:"read"` | record `{message_id}`; 200 `{"success":true}` |
| … with neither or both of `to` / `recipient` | 400 error code 100 |
| … `type:"text"`, window open for the recipient | record; 200 F10 response with a new id `wamid.FAKE<n>` |
| … `type:"text"`, window closed, mode `sync` | 400 with the 8.6 Graph error (code 131047); nothing recorded |
| … `type:"text"`, window closed, mode `async` | record; 200 with a new id; 50 ms later POST the 8.6 failed-status webhook for that id, signed, to `webhookUrl` |
| … `type:"reaction"` | record; 200 with a new id |
| … `type:"template"`, name in the approved set and `language.code === "en"` | record; 200 with a new id |
| … `type:"template"`, otherwise | 400 error code 132001 |
| a pending `/_control/fail` entry for this `type` | that error instead, then decrement its count |

The recipient key is `to` without its leading `+`, or `recipient`. The window for a key is open when the last injected message from that key has a `timestamp` less than 24 hours before the fake's current time, unless the key is sticky-closed.

### 17.2 Control endpoints

| Request | Effect / response |
|---|---|
| `POST /_control/inject {"from":"15551230001","user_id":"US.13491208655302741918","name":"Alice","type":"text","text":"hi","timestamp":1763452800,"id":"wamid.X","omit_from":false}` | builds the 8.6 payload (other `type` values get `{"<type>":{}}` instead of `text`; `omit_from:true` drops `from` and `wa_id`), signs it with `appSecret` (`X-Hub-Signature-256: sha256=<lowercase hex>`), POSTs it to `webhookUrl`, updates the window for `from`. Defaults: `user_id` = `"US." + from`, `name` = `"Alice"`, `type` = `"text"`, `timestamp` = now, `id` = a new `wamid.FAKEIN<n>`. Returns `{"id":"…","status":<hub HTTP status>,"body":"<hub body>"}` |
| `POST /_control/replay {"id":"wamid.X"}` | re-POSTs the exact bytes and signature first sent for that id; returns `{"status":…}` |
| `POST /_control/post {"body":"<raw>","signature":"sha256=…"}` | POSTs raw bytes (`signature: null` omits the header); returns `{"status":…,"body":"…"}` |
| `POST /_control/challenge {"verify_token":"…","challenge":"1158201444"}` | GETs `webhookUrl?hub.mode=subscribe&hub.challenge=…&hub.verify_token=…`; returns `{"status":…,"body":"…","content_type":"…"}` |
| `GET /_control/sent?to=15551230001` | `{"messages":[{"id":"…","to":"15551230001","type":"text","text":"echo: hi","template":null,"reaction":null,"reaction_message_id":null}]}` in send order |
| `GET /_control/reads` | `{"reads":[{"message_id":"…"}]}` |
| `POST /_control/templates {"approved":["ninjy_reply_waiting"]}` | replaces the approved set (initially empty) |
| `POST /_control/window {"to":"15551230001","open":false}` | sticky-closes that key; `{"open":true}` clears the sticky flag |
| `POST /_control/window-mode {"mode":"async"}` | `sync` (default) or `async` |
| `POST /_control/fail {"type":"text","http_status":400,"code":131056,"count":1}` | the next `count` sends of that type fail with that status and code |
| `GET /_control/versions` | `{"versions":["v27.0"]}` (distinct versions seen) |

`server_test.mjs` (run with `node --test tools/fake_whatsapp/server_test.mjs`) covers: auth refusal, identity, text/reaction/read/template recording, template approval, sync and async window failure, signature correctness against an independent `crypto.createHmac`, replay byte-equality, and the fail queue.

## 18. Security

| Risk | Control |
|---|---|
| Forged webhook POSTs (internet-reachable, no login) | HMAC-SHA256 over the raw body with the app secret, constant-time compare (`hmac.verify`), before any parsing (8.3). 401 otherwise |
| Signature brute force or junk floods | Fixed-window limits: 1,200 POSTs/min overall, 20 bad signatures per IP per minute, then 429 for that IP (9.3). 4 MiB body cap (9.2). The hub's own 80 MiB request cap stays as an outer bound (`src/hub/transport/http/server.odin:19`) |
| Endpoint discovery and handshake probing | 404 unless configured and the experiment is on for someone (D6). Handshake only with the exact verify token (constant time), at least 16 characters (14.2), 120 GETs/min overall. The challenge is echoed only when it matches `[0-9A-Za-z._-]{1,128}` and as `text/plain`, so it cannot carry markup |
| Replayed or duplicated events (F3) | `event_key` unique in `channel_push_events` (dedupe before side effects) and `provider_update_key` unique in `channel_messages`. A replayed pairing message cannot pair twice: the code is single use and the event is dropped |
| Events for another WhatsApp account or number on the same app | Skipped unless `entry.id` = configured business account id and `metadata.phone_number_id` = configured phone number id (8.4) |
| A stranger messages the business number | Only bound chats are stored; others get one fixed reply (`COPY_WA_NOT_CONNECTED`). Section 25, Q4 |
| Wrong person in a bound chat | `external_user_id` must equal the binding's (inbound rule 7) |
| Pairing code theft or guessing | Slice 1 rules: 128-bit code, SHA-256 at rest, single use, 10-minute TTL, earlier codes revoked (`pairing.odin:25-44`). The code travels inside WhatsApp, visible to Meta, which already sees every message |
| Bot sends to an arbitrary number | `channel send` has no chat or channel argument; the target is always an active binding of the bot's owner (11.1) |
| Token, app secret, verify token leakage | From env or files only (14.1); never logged; adapter errors are fixed strings (7.1 contract 4); `httpc` diagnostics are never logged (as Telegram, `telegram.odin:30-31`) |
| Personal data in logs | Log lines carry hub ids only: no phone numbers, BSUIDs, names or message text (section 19) |
| Plaintext at rest | Same store and purge rules as Telegram (30 days, on disconnect, on bot delete). Unprocessed webhook bodies live in `channel_push_events.body` only until the intake processes them (blanked in the same transaction) |
| Held replies sent to the wrong person later | Release only to the binding that held them, only while it is active; disconnect purges and expires them (10.5) |
| Prompt injection from WhatsApp text | Unchanged from slice 1 (slice 1 spec 18): the notice says anyone controlling the WhatsApp account controls the bot |
| Cost abuse | Re-engagement at most once per closed window per binding (12.4); no other business-initiated messages |
| Experiment-off isolation | Route 404, intake stopped, per-owner rules (section 20) |

## 19. Logging

All hub lines use the `bots:` prefix and carry only hub ids, counts, kinds and codes. Exact lines (new):

```text
bots: whatsapp configured phone_number_id=<id>
bots: whatsapp disabled: missing HEIMDALL_WHATSAPP_APP_SECRET,HEIMDALL_WHATSAPP_VERIFY_TOKEN
bots: whatsapp intake started
bots: whatsapp intake stopped
bots: whatsapp webhook rejected reason=bad_signature
bots: whatsapp webhook rejected reason=rate_limited
bots: whatsapp webhook ignored reason=bad_payload
bots: whatsapp webhook stored events=<n> new=<m>
bots: whatsapp intake commit failed
bots: reply held binding=<chb_id> chunks=<n>
bots: reengage sent binding=<chb_id>
bots: reengage failed binding=<chb_id> kind=<kind> code=<n>
bots: held released binding=<chb_id> sent=<n> failed=<m> kept=<k>
bots: mark read failed kind=<kind>
```

`bots: whatsapp webhook rejected reason=rate_limited` is printed at most once per limiter window. No new metrics.

## 20. Experiment gating

| Change | Gated by `bots`? | How |
|---|---|---|
| Webhook route (GET and POST) | yes, hub-wide | 404 unless `experiment_count_enabled("bots") > 0` and WhatsApp configured (D6) |
| Intake thread | yes, hub-wide | started by `bots_runtime_reconcile` only when `n > 0` (9.7) |
| Inbound handling, pairing, notices, held release, re-engagement, feedback | yes, per owner | slice 1 rules plus the gate checks in 12.4, 12.5 and 13 |
| `/api/v1/bots/me/channels/whatsapp/*` | yes, per user | `bot_require_auth` + experiment check, like every bots route |
| Settings > Bots WhatsApp card | yes | inside the Bots panel, which is hidden when the experiment is off |
| Migration 210 | no | schema only; the new rows and columns are inert without the experiment |
| Config keys and validation | no | inert; no thread or route without the experiment |
| Adapter interface fields, Telegram edits | no | Telegram behaviour is identical (7.2) |
| `src/templates/bot.md`, `ham-ctl channel` help | no | text read only by bot instances, which exist only when the experiment was on |
| `qrcode-generator` dependency | no | bundled UI code, used only by the card |

## 21. Test plan

Odin tests run per package with a unique output: `odin test <pkg> -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/<unique>`. UI tests run with `npm test` (`tests/ui_bots_test.ts` is already in the `test` script, `package.json:14`). Fake servers: `node --test tools/fake_whatsapp/server_test.mjs`. Pre-existing failures on the base commit are waived only when named with evidence (chain summary).

### 21.1 Unit tests (named; each ticket adds its own)

| Ticket | File | Tests |
|---|---|---|
| W1 | `src/hub/domain/bot_test.odin` | `test_channel_push_kind_text_roundtrip`, `test_channel_send_state_held_roundtrip` |
| W1 | `src/hub/repository/sqlite/bot_repo_sqlite_test.odin` | `test_migration_210_carries_existing_rows` (run migrations with `stop_before = "210_bots_whatsapp.sql"`, insert one Telegram binding, pairing, inbound and outbound message, apply 210, assert every value and `''` new columns), `test_migration_210_allows_whatsapp_and_held`, `test_migration_210_skip_guard_marks_applied`, `test_push_events_insert_dedupes_event_key`, `test_push_batch_commit_is_atomic` (rows, touches and processed marks all or none), `test_push_batch_touch_keeps_latest_and_clears_reengage`, `test_binding_get_active_by_user`, `test_bindings_active_for_owner_orders_telegram_first`, `test_binding_set_reengage_only_active`, `test_messages_mark_replied_binding_is_scoped`, `test_messages_held_oldest_first_excludes_purged`, `test_purge_expires_held_rows`, `test_message_get_outbound_by_external`, `test_push_events_purge_processed_keeps_unprocessed` |
| W1 | `src/hub/app/config_bind_test.odin` | `test_whatsapp_config_state` (one case per row of 14.2) |
| W1 | `src/hub/whatsapp_env_test.odin` (package `main`) | `test_apply_whatsapp_env_inline_file_and_trim`, `test_whatsapp_flags_override_env` |
| W2 | `src/hub/service/bots/pairing_test.odin` | `test_whatsapp_pairing_link_and_text`, `test_whatsapp_pairing_rules_use_whatsapp_copy` (each row of slice 1 spec 9.6), `test_pairing_sets_last_inbound_at`, `test_inbound_lookup_falls_back_to_user_id`, `test_disconnect_is_provider_scoped`, `test_delete_bot_disconnects_both_providers`, `test_notice_goes_to_origin_channel`, `test_telegram_inbound_rules_unchanged` (re-runs every slice 1 inbound row through the generalized procs) |
| W2 | `src/hub/transport/http/bot_handlers_test.odin` | `test_whatsapp_pairing_route_not_configured`, `test_whatsapp_pairing_route_returns_text_and_phone`, `test_whatsapp_disconnect_route`, `test_bot_view_whatsapp_block`, `test_telegram_pairing_response_unchanged` |
| W3 | `src/hub/service/channel/whatsapp_test.odin` (starts `tools/fake_whatsapp/server.mjs` like `telegram_test.odin:19-37`) | `test_whatsapp_push_parse_text_fixture` (8.6 verbatim), `test_whatsapp_signature_rules` (missing header, wrong prefix, short hex, uppercase hex accepted, wrong secret, body changed by one byte), `test_whatsapp_signature_over_raw_escaped_unicode`, `test_whatsapp_push_parse_kinds` (each row of 8.4, plus a failed status, a delivered status skipped, `value.errors` skipped), `test_whatsapp_skips_foreign_account_and_number`, `test_whatsapp_bsuid_only_message` (`omit_from`), `test_whatsapp_identity_and_pairing_url`, `test_whatsapp_send_text_and_address_forms` (`to` with `+`; `recipient` for a BSUID), `test_whatsapp_mark_read_and_react_bodies`, `test_whatsapp_reengage_template_body`, `test_whatsapp_error_mapping` (each row of 8.5), `test_whatsapp_failure_kind_matches_request_mapping`, `test_whatsapp_secrets_never_in_error_message`, `test_whatsapp_uses_pinned_graph_version` |
| W3 | `tools/fake_whatsapp/server_test.mjs` | the list in 17.2 |
| W4 | `src/hub/service/bots/routing_test.odin` | `test_read_binding_rules` (each rule of 11.1), `test_reply_binding_rules` (each rule), `test_send_marks_replied_only_target_binding`, `test_other_channel_stays_pending_and_redelivers` (R3 opens a new delivery), `test_pending_total_counts_all_channels` |
| W4 | `src/hub/service/bots/window_test.odin` | `test_window_closed_margin`, `test_send_holds_when_window_closed`, `test_send_holds_rest_on_window_closed_error`, `test_notice_not_held_when_window_closed`, `test_reengage_once_per_closed_window`, `test_reengage_template_unavailable_sets_error`, `test_reengage_other_error_sets_send_failed`, `test_release_held_in_order_and_stops_on_window_closed`, `test_delivery_failed_window_marks_held_and_reengages`, `test_delivery_failed_other_marks_failed`, `test_telegram_never_holds` |
| W4 | `src/hub/service/bots/feedback_test.odin` | `test_mark_read_newest_then_react`, `test_mark_read_transient_skips_reactions`, `test_feedback_budget_shared`, `test_telegram_feedback_unchanged` |
| W4 | `src/hub/transport/http/bot_agent_handlers_test.odin` | `test_channel_read_returns_channel_field`, `test_channel_send_reply_goes_to_origin`, `test_channel_send_held_response`, `test_channel_history_channel_field`, `test_channel_routes_not_paired_without_bindings` |
| W4 | `src/ctl/channel_cmds_test.odin` | update `test_channel_help_text` (`channel_cmds_test.odin:56`) to the 11.5 text |
| W4 | `src/hub/domain/builtin_templates_test.odin` | `test_bot_template_mentions_whatsapp_and_held` |
| W5 | `src/hub/transport/http/bot_webhook_handlers_test.odin` | `test_webhook_404_when_not_configured_or_experiment_off`, `test_webhook_get_rules` (each GET row of 9.4), `test_webhook_post_rules` (each POST row), `test_webhook_bad_signature_ip_limit`, `test_webhook_global_rate_limit`, `test_webhook_store_failure_returns_503`, `test_webhook_stores_before_200` |
| W5 | `src/hub/service/bots/push_test.odin` | `test_push_receive_dedupes_redelivery`, `test_intake_processes_once_and_blanks_body`, `test_intake_commit_failure_retries_same_events`, `test_intake_release_before_side_effects`, `test_intake_touches_last_inbound_at`, `test_runtime_starts_intake_only_with_whatsapp_and_experiment`, `test_intake_signal_wakes_promptly`, `test_bots_package_does_not_import_transport` (existing test, `gate_test.odin`, must still pass) |
| W6 | `tests/ui_bots_test.ts` | `whatsAppCardState` (four states), `whatsAppQrDataUrl` returns a `data:image/gif;base64,` URL, the 16.2 copy for each reminder value, Settings copy updates |

### 21.2 End-to-end (isolated local hub, fake WhatsApp and fake Telegram) — W7

**File:** `tests/e2e/bots_whatsapp_e2e.mjs`, run with `nix develop -c node tests/e2e/bots_whatsapp_e2e.mjs`. It copies the harness of `tests/e2e/bots_slice1_e2e.mjs` (evidence root, `run`, `poll`, `request`, `sql`, `step`, Puppeteer check; `bots_slice1_e2e.mjs:1-128`) with one bridge. `tests/e2e/bots_slice1_e2e.mjs` MUST still pass unchanged (Telegram regression); W7 runs both.

**Setup** (never the live hub or bridge; free ports from `freePort`):

- Fake Telegram as in slice 1; fake WhatsApp with `webhookUrl = http://127.0.0.1:<hubPort>/api/v1/channels/whatsapp/webhook`.
- Hub env: the slice 1 Telegram and timer variables (`bots_slice1_e2e.mjs:52-56`) plus `HEIMDALL_WHATSAPP_ACCESS_TOKEN=TEST-WA-TOKEN`, `HEIMDALL_WHATSAPP_APP_SECRET=test-app-secret`, `HEIMDALL_WHATSAPP_VERIFY_TOKEN=test-verify-token-0001`, `HEIMDALL_WHATSAPP_PHONE_NUMBER_ID=100000000000001`, `HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID=200000000000002`, `HEIMDALL_WHATSAPP_API_BASE=http://127.0.0.1:<waPort>`, started with `scripts/local-hub.sh start --name bots-wa-e2e …` and one `scripts/local-bridge.sh start --name bots-wa-e2e-a …` on free ports, provider `tools/mock_agent/bot-agent.sh` as in slice 1.
- **Assumption A7** (verify in W7): `scripts/local-hub.sh` passes `HEIMDALL_*` variables through to `ham-hub`, as the slice 1 e2e relies on (`bots_slice1_e2e.mjs:24-25`, `:52-56`). If not, W7 adds a pass-through for exactly the six WhatsApp variables.

**Steps** (each asserts through the user API, `GET /_control/sent`, and SQL where named):

| # | Step | Expected |
|---|---|---|
| 0 | experiment off: `/_control/challenge` with the right token; `/_control/inject` "hi" | both 404; hub log has `bots: whatsapp configured` and no `bots: whatsapp intake started` |
| 1 | enable experiment, `POST /bots/me` | log `bots: whatsapp intake started`; view `whatsapp.configured:true`, `phone_display:"+15550100001"` |
| 2 | `/_control/challenge` right token, then wrong token | 200 `text/plain` body `1158201444`; then 403 |
| 3 | `/_control/post` with a bad signature, 21 times | first 20 → 401; the 21st → 429 |
| 4 | `POST …/channels/whatsapp/pairing`; inject `pairing_text` | `pairing_url` starts with `https://wa.me/15550100001?text=Connect%20Ninjy%20`; binding active; sent has `COPY_WA_PAIRED` |
| 5 | inject "hi" | sent has `echo: hi`; `/_control/reads` has the inbound id; sent has a 👀 reaction for it; `/_control/versions` is `["v27.0"]` |
| 6 | `/_control/replay` the "hi" id | 200; exactly one `channel_messages` row with that update key; no second `echo: hi` |
| 7 | pair Telegram (slice 1 flow); inject Telegram "tg?" then WhatsApp "wa?" | Telegram receives `echo: tg?` only; WhatsApp receives `echo: wa?` only |
| 8 | templates approved = `[]`; window-mode `sync`; sticky-close `15551230001`; inject "late?" | the fake refuses the reply with 131047; no `echo: late?` in sent; view `held_replies[0].body == "echo: late?"`, `reengage_error == "template_unavailable"`; SQL row `send_state='held'` |
| 9 | templates approved = `["ninjy_reply_waiting"]`; inject "late2?" (window still sticky-closed) | the release attempt keeps "echo: late?" held; sent has template `ninjy_reply_waiting` exactly once; view `reengage_sent:true`, two held replies |
| 10 | clear the sticky window; inject "here" | sent has `echo: late?`, `echo: late2?`, then `echo: here`, in that order; `held_replies` empty |
| 11 | window-mode `async`; sticky-close again; inject "async?" | the fake accepts the reply, then posts the failed status; SQL row for `echo: async?` becomes `held`; sent has the template once more (step 10's message cleared `reengage_sent_at`) |
| 12 | clear the sticky window; inject "back" | `echo: async?` arrives before `echo: back` |
| 13 | inject an `image` message | sent has `COPY_UNSUPPORTED` |
| 14 | browser: Settings > Bots | `settings-bots-whatsapp-card` shows "Connected to Alice"; disconnect-confirm flow works through the UI; after it `settings-bots-whatsapp-connect-btn` is visible, and a new connect shows `settings-bots-whatsapp-qr` |
| 15 | re-pair, then inject "disconnect" | sent has `COPY_DISCONNECTED`; Telegram binding still active; inject "hi" → `COPY_WA_NOT_CONNECTED` |
| 16 | disable the experiment | webhook 404; log `bots: whatsapp intake stopped` |

**Teardown:** stop the bridge, the hub and both fake servers; `local-bridge.sh stop --purge-home`.

## 22. Tickets

**Rules for every ticket** (as slice 1 spec 21):

- Commit on the task branch with subjects in the repo style (`Hub: …`, `UI: …`, `ctl: …`, `tools: …`, `docs: …`). Never push.
- Report the exact test commands and outcomes.
- **Never edit** (any ticket): `src/bridge/**`, `src/hub/service/bots/delivery.odin`, `src/hub/service/bots/placement.odin`, `src/contracts/bot_wire.odin`, `src/lib/vault/**`, `src/hub/service/taskv2/**`, `src/prompts/skills/**`, migrations other than the new `210_bots_whatsapp.sql`, `tests/e2e/bots_slice1_e2e.mjs`.
- `src/hub/service/*` MUST NOT import `src/hub/transport/http` (`test_bots_package_does_not_import_transport` guards `bots`). Provider calls never run inside a SQLite write transaction or under `Bots_Service.mutex`.

### W1 — Hub foundation: migration, domain, repository, adapter types, config

**Implements:** 5, 6, 7.1, 7.2 (only `inbound_destroy_batch`), 14.1, 14.2.
**Files:** `src/hub/repository/sqlite/migrations/210_bots_whatsapp.sql`, `src/hub/repository/sqlite/migrations.odin`, `src/hub/domain/bot.odin`, `src/hub/domain/bot_test.odin`, `src/hub/repository/iface/bot_repo.odin`, `src/hub/repository/sqlite/bot_repo_sqlite.odin`, `src/hub/repository/sqlite/bot_repo_sqlite_test.odin`, `src/hub/service/channel/adapter.odin`, `src/hub/service/channel/telegram.odin` (only `inbound_destroy_batch`), `src/hub/app/config_bind.odin`, `src/hub/app/config_bind_test.odin`, `src/hub/main.odin`, `src/hub/whatsapp_env_test.odin`. Exception to the list below: any `switch` over `Channel_Send_State` or `Channel_Error_Kind`, in any file, that stops compiling gets the new cases and nothing else.
**Do not touch:** `src/hub/service/bots/**`, `src/hub/transport/**`, `src/hub/app/wiring.odin`, `src/ui/**`, `tools/**`.
**Tests:** W1 rows of 21.1.
**Done when:** `odin build src/hub -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/w1-hub` succeeds; the domain, sqlite, app and main test packages pass; on a copy of a slice-1 database (made by the migration test) every row survives.
**Depends on:** none.

### W2 — Provider-neutral bots service: inbound, pairing, disconnect, notices, user routes and view

**Implements:** 10, 15, 12.2, 12.3 step 1 only (adapter lookup in `channel_send`), `bots_reply_binding` and `bots_notice_binding` of 11.1.
**Files:** `src/hub/service/bots/{service.odin, inbound.odin, pairing.odin, poller.odin, copy.odin, supervisor.odin (only Bot_Notice, its queueing and sending), channel_send.odin (only the adapter lookup), routing.odin (`bots_reply_binding`, `bots_notice_binding`), window.odin (12.2 only)}`, their `_test.odin` files, `src/hub/transport/http/bot_handlers.odin`, `src/hub/transport/http/bot_handlers_test.odin`, `src/hub/app/wiring.odin` (only the two WhatsApp user routes), `src/ui/api/endpoints/bots.ts` (types and the two endpoints of 15.2).
**Do not touch:** `feedback.odin`, `bot_agent_handlers.odin`, `runtime.odin`, `src/hub/service/channel/**`, `src/ui/components/**`.
**Tests:** W2 rows of 21.1, and every existing test in `src/hub/service/bots` and `src/hub/transport/http` that covers Telegram still passes.
**Done when:** the Telegram pairing, disconnect and inbound tests pass unchanged except for call-site signature updates; the WhatsApp routes answer with an in-process fake adapter.
**Depends on:** W1.

### W3 — WhatsApp adapter and fake WhatsApp server

**Implements:** 2.1, 8, 17.
**Files:** `src/hub/service/channel/whatsapp.odin`, `src/hub/service/channel/whatsapp_test.odin`, `tools/fake_whatsapp/server.mjs`, `tools/fake_whatsapp/server_test.mjs`, `tools/fake_whatsapp/README.md`.
**Do not touch:** `adapter.odin`, `telegram.odin`, everything outside the listed files.
**Tests:** W3 rows of 21.1.
**Done when:** `odin test src/hub/service/channel -collection:odin_test=src -out:$HOME/.cache/heimdall-tests/w3-channel` and `node --test tools/fake_whatsapp/server_test.mjs` pass.
**Depends on:** W1.

### W4 — Reply routing, 24-hour window, read feedback, agent routes, bot-facing text

**Implements:** 11, 12, 13.
**Files:** `src/hub/service/bots/{routing.odin, window.odin, channel_send.odin, feedback.odin, inbound.odin (only bots_channel_replied), service.odin (only the `reengage_mutex` field), supervisor.odin (only the retention call of 12.7)}` and their tests, `src/hub/transport/http/bot_agent_handlers.odin`, `src/hub/transport/http/bot_agent_handlers_test.odin`, `src/ctl/channel_cmds.odin`, `src/ctl/channel_cmds_test.odin`, `src/ctl/agent_mode.odin` (only line 1878), `src/templates/bot.md` (only the lines named in 11.6), `src/hub/domain/builtin_templates_test.odin`.
**Do not touch:** `pairing.odin` rules, `poller.odin`, `runtime.odin`, `src/hub/service/channel/**`, `src/ui/**`, any other line of `bot.md`.
**Tests:** W4 rows of 21.1.
**Done when:** `odin test` for `src/hub/service/bots`, `src/hub/transport/http`, `src/ctl` and `src/hub/domain` pass; the bridge relay still sees reads (an existing bridge test is not needed: the `messages` key is unchanged).
**Depends on:** W2.

### W5 — Webhook route, push receive, intake thread, runtime, wiring, `SELF_HOSTING.md`

**Implements:** 9, 14.3, the wiring half of 14.2.
**Files:** `src/hub/transport/http/bot_webhook_handlers.odin`, `src/hub/transport/http/bot_webhook_handlers_test.odin`, `src/hub/service/bots/push.odin`, `src/hub/service/bots/push_test.odin`, `src/hub/service/bots/runtime.odin`, `src/hub/service/bots/poller_test.odin` (only `bots_runtime_stop_locked` call-site updates), `src/hub/app/wiring.odin` (9.8 and the two webhook routes), `SELF_HOSTING.md`.
**Do not touch:** `src/hub/service/channel/**`, inbound/pairing/window procs (call them only), `src/ui/**`.
**Tests:** W5 rows of 21.1.
**Done when:** the W5 tests pass; a hub started with the fake WhatsApp variables logs `bots: whatsapp configured` and, after enabling the experiment for one user, `bots: whatsapp intake started`; `curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:<port>/api/v1/channels/whatsapp/webhook?hub.mode=subscribe&hub.challenge=1&hub.verify_token=wrong'` prints `403`.
**Depends on:** W2, W3, W4.

### W6 — UI: Settings > Bots WhatsApp card

**Implements:** 16.
**Files:** `src/ui/components/settings/BotWhatsAppCard.tsx`, `src/ui/components/settings/BotsPanel.tsx`, `src/ui/components/settings/botsView.ts`, `src/ui/components/settings/SettingsModal.tsx` (only line 85), `src/ui/components/settings/experimentFlags.ts` (only line 60), `tests/ui_bots_test.ts`, `docs/ui-debug-ids.md`, `package.json`, `package-lock.json`, `flake.nix` (only `npmDepsHash`, `flake.nix:27`), and `src/ui/types/qrcode-generator.d.ts` only under Assumption A9's fallback.
**Do not touch:** `BotTelegramCard.tsx`, `src/ui/api/endpoints/bots.ts` (W2 owns it), any hub file.
**Tests:** W6 row of 21.1; `npm test`; `npx tsc --noEmit -p .` (the repo's type check); `nix build .#<ui package>` to confirm the new `npmDepsHash`.
**Done when:** the card renders each state against a mocked view in the unit tests; the type check and the Nix UI build pass.
**Depends on:** W2.

### W7 — End-to-end run on an isolated hub

**Implements:** 21.2.
**Files:** `tests/e2e/bots_whatsapp_e2e.mjs`; `scripts/local-hub.sh` only under Assumption A7's fallback.
**Do not touch:** product code. A product defect found here is reported to the coordinator with the failing step; it is fixed in the owning ticket.
**Done when:** `nix develop -c node tests/e2e/bots_whatsapp_e2e.mjs` prints `PASS` for all 17 steps and `nix develop -c node tests/e2e/bots_slice1_e2e.mjs` still passes; evidence directory named in the handoff.
**Depends on:** W5, W6.

### W8 — Staging rollout (operator-assisted)

**Implements:** U4, F22–F24.
**Files:** in `~/nix-homelab-config` on dawnstar only (the hub service definition and its sops secret declarations). Nothing in this repository.
**Do not touch:** the production hub, any other host, the Meta app's production settings, `secrets/trusted/ai/heimdall.yaml` contents (the five `mundus_whatsapp_*` values already exist).

**Nix wiring** (**Assumption A8**, verify first: the staging hub runs from a NixOS service in `~/nix-homelab-config` whose Telegram token is a sops secret passed as `HEIMDALL_TELEGRAM_BOT_TOKEN_FILE`. If it is wired differently, mirror whatever the Telegram token uses):

1. Declare five sops secrets from `secrets/trusted/ai/heimdall.yaml`: `mundus_whatsapp_access_token`, `mundus_whatsapp_app_secret`, `mundus_whatsapp_verify_token`, `mundus_whatsapp_phone_number_id`, `mundus_whatsapp_business_account_id`, readable by the hub service user, like the Telegram secret.
2. Add to the hub service environment:
   ```nix
   HEIMDALL_WHATSAPP_ACCESS_TOKEN_FILE = config.sops.secrets.mundus_whatsapp_access_token.path;
   HEIMDALL_WHATSAPP_APP_SECRET_FILE = config.sops.secrets.mundus_whatsapp_app_secret.path;
   HEIMDALL_WHATSAPP_VERIFY_TOKEN_FILE = config.sops.secrets.mundus_whatsapp_verify_token.path;
   HEIMDALL_WHATSAPP_PHONE_NUMBER_ID_FILE = config.sops.secrets.mundus_whatsapp_phone_number_id.path;
   HEIMDALL_WHATSAPP_BUSINESS_ACCOUNT_ID_FILE = config.sops.secrets.mundus_whatsapp_business_account_id.path;
   ```
3. Pin the hub to the `feat/bots` build containing W1–W6 with `offTag = true` (chain summary "Deploy pitfalls"). No bridge swap is needed (D7).
4. Deploy; check the hub log for `bots: whatsapp configured phone_number_id=…` and, with the `bots` experiment on for the operator, `bots: whatsapp intake started`. A `bots: whatsapp disabled: …` line means a secret is missing or malformed (14.2).
5. Check the reverse proxy forwards the path: `curl -s -o /dev/null -w '%{http_code}' 'https://hub.mundus.in/api/v1/channels/whatsapp/webhook?hub.mode=subscribe&hub.challenge=1&hub.verify_token=wrong'` prints `403`.

**Meta dashboard steps for the operator** (the agent lists them in the handoff and waits for the user where marked):

| # | Step |
|---|---|
| M1 | In the Meta app (WhatsApp product), note the test number's **Phone number ID** and the **WhatsApp Business Account ID**; they must equal the stored `mundus_whatsapp_phone_number_id` and `mundus_whatsapp_business_account_id` |
| M2 | Confirm `mundus_whatsapp_access_token` is a **system-user token** (Business Settings > System users) with `business_management`, `whatsapp_business_messaging`, `whatsapp_business_management`, assigned the app and the WhatsApp account with full control (F22). A temporary dashboard token expires quickly |
| M3 | Confirm `mundus_whatsapp_app_secret` equals App settings > Basic > App secret |
| M4 | WhatsApp Manager > Message templates: create `ninjy_reply_waiting`, category Utility, language English (`en`), body exactly as in 12.4, no header, footer, buttons or variables. Submit (approval is asynchronous; the hub works without it, 12.4) |
| M5 | API Setup: add each staging tester's phone number to the test number's recipient list and verify it by code (F23) |
| M6 | (user) With the hub deployed and the experiment on: WhatsApp > Configuration: Callback URL `https://hub.mundus.in/api/v1/channels/whatsapp/webhook`, Verify token = the stored verify token, **Verify and save**; then subscribe the `messages` webhook field |
| M7 | Subscribe the app to the account (F24), from a shell with the token in a file, never echoed: `curl -s -X POST -H "Authorization: Bearer $(cat <token file>)" https://graph.facebook.com/v27.0/<WABA_ID>/subscribed_apps` → `{"success":true}` |
| M8 | If inbound messages do not arrive while the app is in Development mode (F24), switch the app to Live (needs a privacy policy URL) |
| M9 | (user) From a recipient phone: Settings > Bots > Connect WhatsApp, open the link or scan the QR, send the prefilled message, get `COPY_WA_PAIRED`; send "hi", see 👀, blue ticks and a reply; send "disconnect" and see `COPY_DISCONNECTED`; reconnect |
| M10 | When M4 is approved: send the template once to the operator's number with the curl body of 8.2 (template) to confirm `{"messages":[{"id":…}]}`; the 24-hour path itself is covered by W7 |

**Done when:** M1–M9 pass on staging, with the hub log lines and the user's confirmation recorded in the handoff; M10 recorded when the template is approved (not blocking).
**Depends on:** W7.

### Ticket graph

| Ticket | Depends on | Can run in parallel with |
|---|---|---|
| W1 | — | — |
| W2 | W1 | W3 |
| W3 | W1 | W2, W4, W6 |
| W4 | W2 | W3, W6 |
| W5 | W2, W3, W4 | W6 |
| W6 | W2 | W3, W4, W5 |
| W7 | W5, W6 | — |
| W8 | W7 | — |

## 23. Traceability

| Requirement | Sections | Tickets |
|---|---|---|
| REQ-WA-1 | 2 (F1), 8.2 (`whatsapp_push_challenge`), 9.4 GET, 14.2 | W3, W5, W8 |
| REQ-WA-2 | 2 (F2), 8.3, 9.4 POST rows 3–4, 18 | W3, W5 |
| REQ-WA-3 | D1, 5.2 (`channel_push_events`), 6.3 (`push_events_insert`, `push_batch_commit`), 9.5, 9.6 | W1, W5 |
| REQ-WA-4 | D5, 10.2–10.5, 15.1, 16 | W2, W3, W6 |
| REQ-WA-5 | D3, 11.1, 11.3, 18 | W4 |
| REQ-WA-6 | 1.2 (no delivery engine change), 9.6 step 8, 10.6 | W2, W5, W7 |
| REQ-WA-7 | D4, 12, 15.2, 16.2 | W4, W6 |
| REQ-WA-8 | 2 (F11, F12), 8.2, 13 | W3, W4 |
| REQ-WA-9 | 8.4 (Unsupported), 10.2 rule 6 | W2, W3 |
| REQ-WA-10 | 7, 10.1, 10.3 note, 12.6 (`failure_kind`) | W1, W2, W4 |
| REQ-WA-11 | 14, 18, 19, 20 | W1, W5, W8 |
| REQ-WA-12 | 9.3, 17, 21 | W3, W5, W7 |
| U1 | D3, 11 | W4 |
| U2 | D4, 12, 16.2 | W4, W6, W8 (M4) |

## 24. Assumptions

| # | Assumption | Verified by | Fallback if false |
|---|---|---|---|
| A1 | `channel_bindings`, `channel_pairings` and `channel_messages` have no foreign keys, triggers or views pointing at them on staging (true in the repository: only `209_bots.sql` defines them) | W1 (`SELECT sql FROM sqlite_master WHERE sql LIKE '%channel_%'` on a migrated test database) | Drop and recreate the dependent object inside the 210 transaction |
| A2 | Meta sends `X-Hub-Signature-256` on every POST, including status webhooks (F2 states it for POSTs generally) | W8 (staging pairing works) | none needed: unsigned POSTs are refused, which is the safe outcome; report to the coordinator |
| A3 | `131047` can arrive synchronously or asynchronously (F15) | W7 covers both via the fake; W8 cannot force it | both paths are built; nothing to change |
| A4 | The test number limits recipients to verified numbers (F23) | W8 M5 | none needed |
| A5 | `hub.challenge` matches `[0-9A-Za-z._-]{1,128}` (Meta documents it as an int, F1) | W8 M6 | W5 widens the allowed set to printable ASCII without spaces, still `text/plain` |
| A6 | A template without parameters is sent without `components` (F17) | W8 M10 | W3 adds `"components":[]` to the template body |
| A7 | `scripts/local-hub.sh` passes `HEIMDALL_*` through (the slice 1 e2e relies on it) | W7 | W7 adds a pass-through for the six WhatsApp variables |
| A8 | Staging's Telegram token is a sops secret passed as `HEIMDALL_TELEGRAM_BOT_TOKEN_FILE` in `~/nix-homelab-config` on dawnstar (not readable from this machine) | W8 step 0 | mirror the Telegram wiring as found |
| A9 | `qrcode-generator@1.4.4` ships TypeScript declarations | W6 | add `src/ui/types/qrcode-generator.d.ts` for the four calls used |
| A10 | Webhook POSTs reach the hub's `/api/v1/*` through the staging reverse proxy unchanged (raw body, `X-Hub-Signature-256` header kept) | W8 step 5 and M6 | W8 adds a pass-through rule for the path in the proxy config next to the hub's other `/api/v1` routing |

Verified during spec writing (no longer assumptions): `header_value` matches header names case-insensitively (`src/hub/transport/http/server.odin:239-244`); routes registered with `router_add` carry no implicit authentication (Paddle webhook, `wiring.odin:700`).

## 25. Open questions for the coordinator (defaults are what gets built)

| # | Question | Default built |
|---|---|---|
| Q1 | The bridge notice says "New Telegram message for you" for WhatsApp messages too. Change it to "New message for you" in a later bridge release? | No bridge change now; the template explains it (11.6) |
| Q2 | Graph API v27.0 is two weeks old. Pin v26.0 instead? | v27.0, matching Meta's current examples (F20) |
| Q3 | Add Meta webhook mTLS (client certificate `client.webhooks.fbclientcerts.com`) at the reverse proxy? | No; HMAC plus rate limits (18) |
| Q4 | Rate-limit `COPY_WA_NOT_CONNECTED` per chat for strangers writing to a future public number? | No throttle (the staging test number only reaches allow-listed numbers) |
| Q5 | A user who changes phone number gets a new BSUID (F7) and must reconnect. Handle `system.user_changed_number` automatically? | No; the user reconnects from Settings |
| Q6 | Utility templates are charged since 2026-10-01 (F19). Acceptable for the one reminder per closed window? | Yes |
| Q7 | Held replies wait up to the 30-day retention. Expire them sooner? | No; 30 days, like every message body |

## 26. Evidence index (base `d3c9ad2b`)

| Reference | What is there |
|---|---|
| `docs/plans/bots-slice-1-spec.md` 8, 9.3–9.7, 11.3, 15, 16, 17.4, 20.3 | adapter contract, poller, inbound rules, pairing table, R2/R3, user API, agent API, UI copy, slice 1 e2e |
| `src/hub/service/channel/adapter.odin:1-40` | current `Channel_Adapter`, `Inbound`, `Channel_Error` |
| `src/hub/service/channel/telegram.odin:19-21` | `telegram_adapter` constructor |
| `src/hub/service/channel/telegram.odin:30-46` | fixed safe error messages, Telegram error mapping |
| `src/hub/service/channel/telegram.odin:55-71` | `telegram_request` (httpc use) |
| `src/hub/service/channel/telegram.odin:94-102` | `inbound_destroy_batch` |
| `src/hub/service/channel/telegram.odin:155-162` | `Inbound` built with named fields |
| `src/hub/service/channel/telegram_test.odin:19-37` | test fixture starting the Node fake server |
| `src/hub/service/bots/poller.odin:21-75` | poll → map → commit → side effects → deliveries |
| `src/hub/service/bots/inbound.odin:13-37` | `bots_inbound_rows`, truncation at `:22-26` |
| `src/hub/service/bots/inbound.odin:39-50` | `bots_inbound_side_effect` (rules 1–6) |
| `src/hub/service/bots/inbound.odin:92-127` | `bots_channel_replied` (R2/R3), `messages_mark_replied` at `:98` |
| `src/hub/service/bots/pairing.odin:23-44` | `Bot_Pairing_Link`, `bots_pairing_create` |
| `src/hub/service/bots/pairing.odin:52-56` | `bots_notice` |
| `src/hub/service/bots/pairing.odin:59-105` | `bots_pairing_start`, `bots_pairing_apply` |
| `src/hub/service/bots/pairing.odin:129-157` | `bots_disconnect`, `_for_reason`, `_locked` |
| `src/hub/service/bots/channel_send.odin:15-112` | chunking and `channel_send` |
| `src/hub/service/bots/feedback.odin:11-70` | read reaction budget and `bots_channel_read` |
| `src/hub/service/bots/copy.odin:3-14` | slice 1 copy |
| `src/hub/service/bots/runtime.odin:11-127` | `Bots_Runtime`, reconcile, stop, wait, entries |
| `src/hub/service/bots/service.odin:15-35` | `Bots_Service` |
| `src/hub/service/bots/service.odin:74-111` | `Bot_Telegram_View`, `Bot_View`, Telegram block of the view |
| `src/hub/service/bots/service.odin:157-216` | `bots_delete` (disconnect at `:164`, pairing delete at `:216`) |
| `src/hub/service/bots/supervisor.odin:16` | `Bot_Notice` |
| `src/hub/service/bots/supervisor.odin:281-310` | notice queueing and sending, retention |
| `src/hub/service/bots/supervisor.odin:313-316` | `bots_queue_gave_up_locked` |
| `src/hub/service/bots/gate.odin:10`, `:27` | `bots_gate_error`, `bots_gate_on` |
| `src/hub/transport/http/bot_agent_handlers.odin:9-101` | channel read/send/history handlers |
| `src/hub/transport/http/bot_handlers.odin:21`, `:171-213` | auth helper; pairing, disconnect, messages handlers |
| `src/hub/transport/http/billing_handlers.odin:65-71` | unauthenticated Paddle webhook handler |
| `src/hub/service/billing/webhook.odin:3`, `:15-37` | `core:crypto/hmac` signature verification |
| `src/hub/service/device_auth/ip.odin:29` | `resolve_client_ip` |
| `src/hub/transport/http/server.odin:19` | `MAX_HTTP_REQUEST_BYTES` |
| `src/hub/transport/http/server.odin:239-244` | case-insensitive `header_value` |
| `src/hub/transport/http/respond.odin:11-19` | `Response` with `content_type` |
| `src/hub/transport/http/content_handlers.odin:612` | `query_value` |
| `src/hub/app/wiring.odin:104-105`, `:627-633`, `:665` | Telegram adapter fields, construction, teardown |
| `src/hub/app/wiring.odin:478` | `forwarded_for_trusted_cidrs` wired for device auth |
| `src/hub/app/wiring.odin:700` | Paddle webhook route |
| `src/hub/app/wiring.odin:822-834` | bots user and agent routes |
| `src/hub/app/app.odin:34` | `bots_runtime_reconcile` at startup |
| `src/hub/app/config_bind.odin:9-13`, `:66`, `:146` | bots config fields, trusted CIDRs, Telegram API base default |
| `src/hub/main.odin:153-154`, `:192-195`, `:407`, `:451-457` | env appliers, Telegram flags, `read_key_file`, `apply_telegram_env` |
| `src/hub/domain/bot.odin:8`, `:34`, `:50`, `:172`, `:186`, `:300` | provider constant, `Channel_Binding`, `Channel_Send_State` and its text procs, `channel_binding_destroy` |
| `src/hub/repository/iface/bot_repo.odin:60-138` | binding, pairing, cursor, message procs |
| `src/hub/repository/sqlite/bot_repo_sqlite.odin:478`, `:499` | binding SELECTs with named columns |
| `src/hub/repository/sqlite/bot_repo_sqlite.odin:629-641` | `messages_mark_replied_sqlite` |
| `src/hub/repository/sqlite/bot_repo_sqlite.odin:972-1033` | `binding_activate_sqlite`, INSERT at `:1012` |
| `src/hub/repository/sqlite/migrations/209_bots.sql:25-78` | channel tables and CHECKs |
| `src/hub/repository/sqlite/migrations/169_provider_profiles.sql` | atomic `BEGIN IMMEDIATE … COMMIT` rebuild pattern |
| `src/hub/repository/sqlite/migrations.odin:664`, `:666`, `:879`, `:918-921`, `:1328-1329`, `:1379` | 209 load, order array, 169 skip-guard and rollback, fallback |
| `src/bridge/bot_delivery.odin:14`, `:447` | bridge notice text; read observation on `data.messages` |
| `src/bridge/wrapper_endpoint.odin:570` | relay notes `agent.channel.read` |
| `src/bridge/agent_api.odin:238`, `:364` | `agent.channel.*` routing and allow-list |
| `src/ctl/channel_cmds.odin:8-12`, `src/ctl/channel_cmds_test.odin:56` | `CHANNEL_HELP` and its test |
| `src/ctl/agent_mode.odin:1878` | agent help line for `channel` |
| `src/templates/bot.md:1-18` | bot template |
| `src/ui/components/settings/BotTelegramCard.tsx:1-51` | card pattern to mirror |
| `src/ui/components/settings/BotsPanel.tsx:15`, `:43`, `:50`, `:54` | polling, empty state, Telegram card, delete dialog |
| `src/ui/components/settings/SettingsModal.tsx:85`, `src/ui/components/settings/experimentFlags.ts:60` | bots description copy |
| `src/ui/api/endpoints/bots.ts:10`, `:18`, `:34-36` | Telegram view type, message type, Telegram endpoints |
| `package.json:14`, `flake.nix:27` | UI test script, `npmDepsHash` |
| `tools/fake_telegram/server.mjs:4`, `:105`, `:108-116` | factory, return, CLI |
| `tests/e2e/bots_slice1_e2e.mjs:1-128`, `:52-56` | e2e harness, hub env |
| `SELF_HOSTING.md:1422-1437` | Telegram configuration section |
