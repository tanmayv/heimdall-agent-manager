package http

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import channel "odin_test:hub/service/channel"
import content "odin_test:hub/service/content"
import random "odin_test:lib/os_random"
import vault "odin_test:lib/vault"

// Phase 0 only. The adapter calls, vault envelope, HTTP chat and SQLite are real.
// Origin, idempotency and canonical redaction are proposed seams, implemented here
// only. The Hub receives tokens and metadata; the key stays with the simulated
// converter (and the authorized reader/author).
NS_CHAT :: "chat_mq"
NS_INPUT :: "spikeInboundConfidentialMarker"
NS_REPLY :: "spikeAuthoredConfidentialMarker"
NS_PENDING :: "spikeQueuedConfidentialMarker"
NS_AT :: "2026-11-28T00:00:00Z"

NS_Result :: enum {
	Stored,
	Sent,
	Vault_Locked,
	Revoked,
	Failed,
}

NS_Conversion :: struct {
	f:    ^ACP_Chat_Fixture,
	bots: ^iface.Bot_Repository,
}

ns_provider :: proc(provider: Ninjy_Spike_Provider) -> string {
	return domain.CHANNEL_PROVIDER_TELEGRAM if provider == .Telegram else domain.CHANNEL_PROVIDER_WHATSAPP
}

ns_bind :: proc(s: ^NS_Conversion, provider: Ninjy_Spike_Provider, row: channel.Inbound, re_pair := false) -> bool {
	owner := s.f.mq.base.owner_user_id
	p := ns_provider(provider)
	id := strings.concatenate({p, "_repair"}) if re_pair else p
	if iface.pairing_insert(s.bots, {code_hash = id, owner_user_id = owner, bot_id = "bot_spike", provider = p, created_at = NS_AT, expires_at = "2027-01-01"}).code != .None do return false
	_, _, err := iface.binding_activate(
		s.bots,
		{
			binding_id = id,
			owner_user_id = owner,
			bot_id = "bot_spike",
			provider = p,
			external_chat_id = row.external_chat_id,
			external_user_id = row.external_user_id,
			state = .Active,
			created_at = NS_AT,
		},
		id,
		NS_AT,
	)
	return err.code == .None
}

ns_ingress :: proc(
	s: ^NS_Conversion,
	provider: Ninjy_Spike_Provider,
	row: channel.Inbound,
	key: ^vault.Vault_Keyring,
) -> (
	string,
	NS_Result,
) {
	p := ns_provider(provider)
	binding, paired, _ := iface.binding_get_active_by_chat(s.bots, p, row.external_chat_id)
	if !paired || binding.owner_user_id != s.f.mq.base.owner_user_id || binding.external_user_id != row.external_user_id do return "", .Revoked
	// Text-only fixture scan over a single conversation. The opaque provider
	// update ID remains in the canonical row after redaction and is scoped by
	// owner, conversation and provider. Production needs a unique lookup/UOW.
	rows, scan_err := iface.content_list_messages(
		&s.f.mq.repo,
		NS_CHAT,
		domain.User_ID(binding.owner_user_id),
		100,
		"",
	)
	if scan_err.code != .None do return "", .Failed
	for stored in rows {
		if stored.direction != "user_to_agent" ||
		   json_string(stored.metadata_json, "provider") != p ||
		   json_string(stored.metadata_json, "provider_update_key") != row.update_key {
			continue
		}
		if stored.body == "" do return "", .Revoked
		return stored.message_id, .Stored
	}
	sealed, ok := vault.seal_string(row.text, key)
	if !ok do return "", .Vault_Locked
	auth := contracts.Auth_Context {
		kind    = .Internal_User,
		user_id = s.f.mq.base.owner_user_id,
	}
	meta, meta_err := json.marshal(struct {
			origin_binding_id, provider, provider_update_key: string,
		}{binding.binding_id, p, row.update_key})
	if meta_err != nil do return "", .Failed
	message, saved, _ := content.persist_user_message(
		&s.f.mq.svc,
		auth,
		NS_CHAT,
		{body = sealed, metadata_json = string(meta)},
	)
	if !saved do return "", .Failed
	return message.message_id, .Stored
}

// The proposed adapter can surface a safe retry instruction without a body or
// recipient and retain the provider's logical input on its own side.
ns_intake_response :: proc(
	s: ^NS_Conversion,
	provider: Ninjy_Spike_Provider,
	row: channel.Inbound,
	key: ^vault.Vault_Keyring,
) -> Response {
	_, status := ns_ingress(s, provider, row, key)
	if status == .Vault_Locked do return {status = 503, body = `{"error":"vault_locked","retryable":true}`}
	if status == .Stored do return {status = 201}
	return {status = 409}
}

ns_agent_request :: proc(s: ^NS_Conversion, verb, body: string) -> Request {
	req := mq_http_req(s.f.mq.base, fmt.tprintf("/api/v1/agent-actions/chat/%s", verb), body)
	req.headers = make([]contracts.HTTP_Header, 2, context.temp_allocator)
	req.headers[0] = {
		name  = "Authorization",
		value = fmt.tprintf("Bearer %s", s.f.mq.base.bridge_token),
	}
	req.headers[1] = {
		name  = "X-Heimdall-Instance-Token",
		value = "hit_inst_mq~epoch",
	}
	return req
}

ns_author :: proc(
	t: ^testing.T,
	s: ^NS_Conversion,
	input_id, text: string,
	author_key: ^vault.Vault_Keyring,
) -> string {
	sealed, seal_ok := vault.seal_string(text, author_key)
	if !testing.expect(t, seal_ok, "authorized author sealed reply") do return ""
	raw := fmt.tprintf(
		`{{"agent_instance_id":"inst_mq","params":{{"body":"%s","metadata":{{"reply_to":"%s","channel_state":"pending"}}}}}}`,
		sealed,
		input_id,
	)
	reply := agent_action_chat_send_to_user_handler(&s.f.mq.agent_handlers, ns_agent_request(s, "send-to-user", raw))
	if !testing.expect(t, reply.status == 201, reply.body) do return ""
	return json_string(json_object_raw(reply.body, "data"), "message_id")
}

ns_transcript :: proc(s: ^NS_Conversion) -> Response {
	req := mq_http_req(s.f.mq.base, "/api/v1/chats/chat_mq/messages", "")
	req.method = "GET"
	return list_chat_messages_handler(&s.f.mq.handlers, req)
}

ns_egress :: proc(
	s: ^NS_Conversion,
	adapters: ^[Ninjy_Spike_Provider]Ninjy_Spike_Channel,
	reply_id: string,
	key: ^vault.Vault_Keyring,
) -> NS_Result {
	repo := &s.f.mq.repo
	owner := domain.User_ID(s.f.mq.base.owner_user_id)
	reply, found, _ := iface.content_get_message(repo, reply_id)
	if !found || reply.owner_user_id != owner || reply.conversation_id != NS_CHAT || reply.direction != "agent_to_user" do return .Failed
	input_id := json_string(reply.metadata_json, "reply_to")
	switch json_string(reply.metadata_json, "channel_state") {
	case "sent":
		return .Sent
	case "revoked":
		return .Revoked
	}
	input, input_found, _ := iface.content_get_message(repo, input_id)
	if !input_found || input.owner_user_id != owner || input.conversation_id != NS_CHAT || input.direction != "user_to_agent" do return .Revoked
	binding, bound, _ := iface.binding_get(s.bots, json_string(input.metadata_json, "origin_binding_id"))
	if !bound || binding.owner_user_id != string(owner) || binding.state != .Active do return .Revoked
	provider: Ninjy_Spike_Provider
	switch binding.provider {
	case domain.CHANNEL_PROVIDER_TELEGRAM:
		provider = .Telegram
	case domain.CHANNEL_PROVIDER_WHATSAPP:
		provider = .WhatsApp
	case:
		return .Failed
	}
	plain, opened := vault.open(reply.body, key)
	if opened != .Ok {
		meta := fmt.tprintf(`{{"reply_to":"%s","channel_state":"vault_locked"}}`, input_id)
		_, ok, _ := iface.content_update_message(
			repo,
			owner,
			NS_CHAT,
			reply_id,
			reply.body,
			reply.message_status,
			meta,
		)
		return .Vault_Locked if ok else .Failed
	}
	receipt, err := ninjy_spike_channel_send(&adapters[provider], binding.external_chat_id, plain)
	if err.kind != .None || receipt == "" do return .Failed
	meta, json_err := json.marshal(struct {
			reply_to, channel_state, provider, provider_receipt: string,
		}{input_id, "sent", binding.provider, receipt})
	if json_err != nil do return .Failed
	_, ok, _ := iface.content_update_message(
		repo,
		owner,
		NS_CHAT,
		reply_id,
		reply.body,
		reply.message_status,
		string(meta),
	)
	return .Sent if ok else .Failed
}

// This is an explicit prototype: canonical chat has no channel purge API yet.
// Clear the payload of this fixture's input and replies, but keep opaque IDs and
// one receipt so retries cannot re-import or send them.
ns_redact :: proc(t: ^testing.T, s: ^NS_Conversion, input_id, sent_id, queued_id: string) -> bool {
	owner := domain.User_ID(s.f.mq.base.owner_user_id)
	repo := &s.f.mq.repo
	for id in ([]string{input_id, sent_id, queued_id}) {
		row, found, _ := iface.content_get_message(repo, id)
		if !testing.expect(t, found && row.owner_user_id == owner && row.conversation_id == NS_CHAT, "purge must be owner/conversation scoped") do return false
		meta := row.metadata_json if id == sent_id || id == input_id else `{"channel_state":"revoked"}`
		_, ok, _ := iface.content_update_message(repo, owner, NS_CHAT, id, "", row.message_status, meta)
		if !testing.expect(t, ok, "body redaction succeeded") do return false
	}
	c, found, _ := iface.content_get_conversation(repo, NS_CHAT)
	if !testing.expect(t, found && c.owner_user_id == owner) do return false
	c.last_message_preview = ""
	_, ok, _ := iface.content_save_conversation(repo, c)
	return testing.expect(t, ok, "preview redaction succeeded")
}

ns_fts_matches :: proc(t: ^testing.T, s: ^NS_Conversion, token: string) -> i64 {
	stmt: sqlite.sqlite3_stmt
	query :: "SELECT count(*) FROM chat_messages_fts WHERE chat_messages_fts MATCH ?;"
	if !testing.expect_value(t, sqlite.sqlite3_prepare_v2(s.f.mq.base.conn.db, query, -1, &stmt, nil), sqlite.SQLITE_OK) do return -1
	defer sqlite.sqlite3_finalize(stmt)
	if !testing.expect_value(t, sqlite.sqlite3_bind_text(stmt, 1, cstring(raw_data(token)), i32(len(token)), sqlite.SQLITE_TRANSIENT), sqlite.SQLITE_OK) do return -1
	if !testing.expect_value(t, sqlite.sqlite3_step(stmt), sqlite.SQLITE_ROW) do return -1
	return sqlite.sqlite3_column_int64(stmt, 0)
}

ns_check_row :: proc(
	t: ^testing.T,
	s: ^NS_Conversion,
	id, plaintext, direction: string,
	key: ^vault.Vault_Keyring,
) -> domain.Chat_Message {
	row, found, _ := iface.content_get_message(&s.f.mq.repo, id)
	if !testing.expect(t, found && row.direction == direction, "chat persistence has matching row") do return {}
	open, result := vault.open(row.body, key)
	testing.expect_value(t, result, vault.Open_Result.Ok)
	testing.expect(t, open == plaintext, "exact text opens with authorized key")
	testing.expect(
		t,
		!strings.contains(row.body, plaintext) && !strings.contains(row.metadata_json, plaintext),
		"body and metadata must not expose text",
	)
	c, preview_found, _ := iface.content_get_conversation(&s.f.mq.repo, NS_CHAT)
	testing.expect(t, preview_found && c.last_message_preview == row.body, "same sealed envelope in durable preview")
	testing.expect_value(t, ns_fts_matches(t, s, plaintext), i64(0))
	return row
}

ns_sends :: proc(
	t: ^testing.T,
	f: ^[Ninjy_Spike_Provider]Ninjy_Spike_Channel,
	provider: Ninjy_Spike_Provider,
	want: int,
	want_address := "",
) -> string {
	other := Ninjy_Spike_Provider.WhatsApp if provider == .Telegram else Ninjy_Spike_Provider.Telegram
	count, address, body, receipt := ninjy_spike_channel_capture(&f[provider])
	other_count, _, _, _ := ninjy_spike_channel_capture(&f[other])
	testing.expect_value(t, count, want)
	testing.expect_value(t, other_count, 0)
	if want > 0 do testing.expect(t, address == want_address && body == NS_REPLY && receipt != "", "one exact provider send to the originating address")
	return receipt
}

NS_Log :: struct {
	outer:          log.Logger,
	plaintext_seen: bool,
}

ns_capture_log :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, loc := #caller_location) {
	capture := (^NS_Log)(data)
	for marker in ([]string{NS_INPUT, NS_REPLY, NS_PENDING}) {
		if strings.contains(text, marker) {
			capture.plaintext_seen = true
			return
		}
	}
	if capture.outer.procedure != nil do capture.outer.procedure(capture.outer.data, level, text, options, loc)
}

ns_roundtrip :: proc(t: ^testing.T, provider: Ninjy_Spike_Provider) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	logs := NS_Log {
		outer = context.logger,
	}
	context.logger = {
		procedure    = ns_capture_log,
		data         = &logs,
		lowest_level = .Debug,
	}
	defer {
		context.logger = logs.outer
		testing.expect(t, !logs.plaintext_seen, "captured caller logs did not expose plaintext")
	}

	base, temp_err := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, temp_err == nil, "resolve test temp directory") do return
	dir, dir_err := os.make_directory_temp(base, "ham-ninjy-spike-*", context.temp_allocator)
	if !testing.expect(t, dir_err == nil, "private test directory") do return
	defer _ = os.remove_all(dir)
	db_path := strings.concatenate({dir, "/chat.sqlite3"})
	f: ACP_Chat_Fixture
	acp_chat_open(t, &f, db_path)
	defer mq_http_base_close(f.mq.base)
	bot_impl: sqlite.Bot_Repo_SQLite
	bots := sqlite.new_bot_repository(&bot_impl, &f.mq.base.conn)
	s := NS_Conversion {
		f    = &f,
		bots = &bots,
	}
	if !testing.expect_value(t, iface.bot_insert(&bots, {bot_id = "bot_spike", owner_user_id = f.mq.base.owner_user_id, agent_instance_id = "inst_mq", created_at = NS_AT, updated_at = NS_AT}).code, domain.Error_Code.None) do return

	key_material: [32]byte
	if !testing.expect(t, random.fill(key_material[:]), "generated disposable key material") do return
	vault_id, _ := vault.vault_id_from_root_sign_pub(acp_chat_root())
	key, key_ok := vault.keyring_from_single_key(f.mq.base.owner_user_id, vault_id, 1, key_material[:])
	crypto.zero_explicit(&key_material, size_of(key_material))
	defer vault.keyring_wipe(&key)
	if !testing.expect(t, key_ok, "test keyring initialized") do return

	adapters: [Ninjy_Spike_Provider]Ninjy_Spike_Channel
	if !ninjy_spike_channel_start(t, &adapters[.Telegram], .Telegram, NS_INPUT) do return
	defer ninjy_spike_channel_stop(&adapters[.Telegram])
	if !ninjy_spike_channel_start(t, &adapters[.WhatsApp], .WhatsApp, NS_INPUT) do return
	defer ninjy_spike_channel_stop(&adapters[.WhatsApp])
	row, ok := ninjy_spike_channel_receive(t, &adapters[provider])
	if !ok || !testing.expect(t, row.kind == .Text && row.text == NS_INPUT && row.chat_is_private, "provider boundary decoded exact paired plaintext") do return
	want_address := "8111" if provider == .Telegram else "15550100123"
	want_wire_address := want_address if provider == .Telegram else "+15550100123"
	want_receipt := "9001" if provider == .Telegram else "wamid.phase-zero-out-1"
	if !testing.expect_value(t, row.external_chat_id, want_address) do return
	if !testing.expect(t, ns_bind(&s, provider, row), "pair originating address") do return
	// A distinct active binding on the same conversation is available, but must
	// not receive the reply. Never infer the route from today's active channel.
	other := Ninjy_Spike_Provider.WhatsApp if provider == .Telegram else Ninjy_Spike_Provider.Telegram
	other_row, other_ok := ninjy_spike_channel_receive(t, &adapters[other])
	if !other_ok || !testing.expect(t, ns_bind(&s, other, other_row), "pair competing address") do return

	ingress_pending := ns_intake_response(&s, provider, row, nil)
	testing.expect_value(t, ingress_pending.status, 503)
	testing.expect_value(t, ingress_pending.body, `{"error":"vault_locked","retryable":true}`)
	before := ns_transcript(&s)
	testing.expect_value(t, before.status, 200)
	testing.expect(
		t,
		!strings.contains(before.body, NS_INPUT) && !strings.contains(before.body, "user_to_agent"),
		"locked ingress wrote no chat row",
	)
	_ = ns_sends(t, &adapters, provider, 0)

	retry_row, retry_ok := ninjy_spike_channel_receive(t, &adapters[provider])
	if !retry_ok || !testing.expect_value(t, retry_row.update_key, row.update_key) do return
	input_id, stored := ns_ingress(&s, provider, retry_row, &key)
	if !testing.expect(t, stored == .Stored && input_id != "", "restored key persisted ingress") do return
	replay_id, _ := ns_ingress(&s, provider, row, &key)
	testing.expect_value(t, replay_id, input_id)
	inbound := ns_check_row(t, &s, input_id, NS_INPUT, "user_to_agent", &key)
	read := agent_action_chat_read_handler(
		&f.mq.agent_handlers,
		ns_agent_request(&s, "read", `{"agent_instance_id":"inst_mq","params":{"mark_read":false}}`),
	)
	testing.expect(t, read.status == 200, read.body)
	testing.expect(
		t,
		inbound.body != "" && strings.contains(read.body, inbound.body) && !strings.contains(read.body, NS_INPUT),
		"ordinary authorized chat read returns ingress ciphertext",
	)
	opened := vault.replace_embedded_tokens(read.body, &key)
	testing.expect(t, strings.contains(opened, NS_INPUT), "authorized reader opens the original provider text")

	reply_id := ns_author(t, &s, input_id, NS_REPLY, &key)
	if reply_id == "" do return
	reply := ns_check_row(t, &s, reply_id, NS_REPLY, "agent_to_user", &key)
	preview_event := agent_to_user_chat_event_json({agent_instance_id = "inst_mq"}, reply)
	testing.expect(
		t,
		reply.body != "" && strings.contains(preview_event, reply.body) && !strings.contains(preview_event, NS_REPLY),
		"user event preview contains only the envelope",
	)
	// Positive FTS control ensures the real, migrated index receives writes.
	testing.expect_value(t, ns_fts_matches(t, &s, "vault"), i64(2))

	testing.expect_value(t, ns_egress(&s, &adapters, reply_id, nil), NS_Result.Vault_Locked)
	pending := ns_transcript(&s)
	testing.expect(
		t,
		pending.status == 200 &&
		strings.contains(pending.body, `"channel_state":"vault_locked"`) &&
		!strings.contains(pending.body, "provider_receipt"),
		"reader sees locked state, with no false delivery receipt",
	)
	_ = ns_sends(t, &adapters, provider, 0)
	testing.expect_value(t, ns_egress(&s, &adapters, reply_id, &key), NS_Result.Sent)
	testing.expect_value(t, ns_egress(&s, &adapters, reply_id, &key), NS_Result.Sent)
	receipt := ns_sends(t, &adapters, provider, 1, want_wire_address)
	testing.expect_value(t, receipt, want_receipt)
	shown := ns_transcript(&s)
	testing.expect(
		t,
		shown.status == 200 &&
		receipt != "" &&
		strings.contains(shown.body, receipt) &&
		strings.contains(shown.body, `"channel_state":"sent"`),
		"owner chat exposes matching provider receipt",
	)
	rows, _ := iface.content_list_messages(&f.mq.repo, NS_CHAT, domain.User_ID(f.mq.base.owner_user_id), 100, "")
	testing.expect_value(t, len(rows), 2)

	queued_id := ns_author(t, &s, input_id, NS_PENDING, &key)
	if queued_id == "" do return
	testing.expect_value(t, ns_egress(&s, &adapters, queued_id, nil), NS_Result.Vault_Locked)
	testing.expect_value(t, iface.binding_revoke(&bots, ns_provider(provider), NS_AT).code, domain.Error_Code.None)
	testing.expect_value(t, ns_egress(&s, &adapters, queued_id, &key), NS_Result.Revoked)
	if !ns_redact(t, &s, input_id, reply_id, queued_id) do return
	// Redelivery/import reconsidering the same provider update cannot restore
	// content. A replacement active pairing still encounters the tombstone.
	_, replay := ns_ingress(&s, provider, row, &key)
	testing.expect_value(t, replay, NS_Result.Revoked)
	if !testing.expect(t, ns_bind(&s, provider, row, re_pair = true), "pair replacement binding") do return
	reopened, reopened_ok, _ := sqlite.open(db_path)
	if !testing.expect(t, reopened_ok, "fresh connection to durable database") do return
	defer sqlite.close(&reopened)
	restarted := f
	restarted.mq.repo = sqlite.new_content_repository(&restarted.mq.impl, &reopened)
	restarted.mq.svc.content = &restarted.mq.repo
	restarted.mq.handlers.content = &restarted.mq.svc
	restarted_bots_impl: sqlite.Bot_Repo_SQLite
	restarted_bots := sqlite.new_bot_repository(&restarted_bots_impl, &reopened)
	restarted_conversion := NS_Conversion {
		f    = &restarted,
		bots = &restarted_bots,
	}
	_, after_repair := ns_ingress(&restarted_conversion, provider, row, &key)
	testing.expect_value(t, after_repair, NS_Result.Revoked)
	testing.expect_value(t, ns_egress(&restarted_conversion, &adapters, queued_id, &key), NS_Result.Revoked)
	_ = ns_sends(t, &adapters, provider, 1, want_wire_address)
	redacted := ns_transcript(&restarted_conversion)
	testing.expect_value(t, redacted.status, 200)
	opened = vault.replace_embedded_tokens(redacted.body, &key)
	for marker in ([]string{NS_INPUT, NS_REPLY, NS_PENDING}) {
		testing.expect(t, !strings.contains(opened, marker), "purged text does not reopen through transcript")
		testing.expect_value(t, ns_fts_matches(t, &s, marker), i64(0))
	}
	testing.expect(
		t,
		!vault.contains_token(redacted.body) && strings.contains(redacted.body, receipt),
		"only receipt and payload-free tombstones remain",
	)
	testing.expect_value(t, ns_fts_matches(t, &s, "vault"), i64(0))
	repo := &restarted.mq.repo
	c, found, _ := iface.content_get_conversation(repo, NS_CHAT)
	testing.expect(t, found && c.last_message_preview == "", "purged preview stays empty after reopen")
	for id in ([]string{input_id, reply_id, queued_id}) {
		row, found, _ := iface.content_get_message(repo, id)
		testing.expect(
			t,
			found && row.body == "" && row.artifact_ids_json == "[]",
			"reopened tombstone has no body or artifact references",
		)
	}
}

@(test)
ninjy_vault_spike_telegram :: proc(t: ^testing.T) {
	ns_roundtrip(t, .Telegram)
}

@(test)
ninjy_vault_spike_whatsapp :: proc(t: ^testing.T) {
	ns_roundtrip(t, .WhatsApp)
}
