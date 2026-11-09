package card

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import content_service "odin_test:hub/service/content"

// Harness: a real migrated SQLite DB with the repositories the projector reads,
// a card service with the projector wired, and source services whose writes
// notify it (exactly as wiring.odin does).
Projector_Harness :: struct {
	path:           string,
	conn:           sqlite.Conn,
	card_impl:      sqlite.Card_Repo_SQLite,
	attention_impl: sqlite.Attention_Repo_SQLite,
	content_impl:   sqlite.Content_Repo_SQLite,
	agent_impl:     sqlite.Agent_Repo_SQLite,
	cards:          iface.Card_Repository,
	attention:      iface.Attention_Repository,
	content:        iface.Content_Repository,
	agents:         iface.Agent_Repository,
	clock:          platform.Clock,
	ids:            platform.ID_Generator,
	content_svc:    content_service.Content_Service,
	svc:            Card_Service,
	changed_kinds:  [dynamic]string,
}

PH_OWNER :: domain.User_ID("usr_attention")
PH_CHAIN :: domain.Task_Chain_ID("chain_att")

ph_open :: proc(t: ^testing.T, h: ^Projector_Harness, name: string) {
	h.path = fmt.aprintf("%s/.cache/heimdall-tests/%s.db", os.get_env("HOME", context.temp_allocator), name)
	os.remove(h.path)
	conn, ok, err := sqlite.open(h.path)
	testing.expectf(t, ok, "open db: %s", err.message)
	h.conn = conn
	mig_ok, mig_err := sqlite.run_migrations(&h.conn)
	testing.expectf(t, mig_ok, "migrations: %s", mig_err.message)
	h.cards = sqlite.new_card_repository(&h.card_impl, &h.conn)
	h.attention = sqlite.new_attention_repository(&h.attention_impl, &h.conn)
	h.content = sqlite.new_content_repository(&h.content_impl, &h.conn)
	h.agents = sqlite.new_agent_repository(&h.agent_impl, &h.conn)
	h.clock = platform.real_clock()
	h.ids = platform.real_id_generator()
	h.content_svc = content_service.Content_Service{content = &h.content, agents = &h.agents, clock = &h.clock, ids = &h.ids}
	h.svc = new_card_service(cards = &h.cards, projects = nil, content = &h.content_svc, clock = &h.clock, ids = &h.ids)
	init_attention(&h.svc, &h.attention)
	// A legacy (read-only) Hub chain record: attention items still resolve its
	// title for scoping context.
	chain_impl: sqlite.Taskchain_Repo_SQLite
	chains := sqlite.new_taskchain_repository(&chain_impl, &h.conn)
	_, chain_ok, _ := iface.taskchain_save_chain(&chains, domain.Task_Chain{chain_id = PH_CHAIN, owner_user_id = PH_OWNER, title = "vault:v2:chain-title", status = .Active, kind = domain.CHAIN_KIND_MIXED_WORK, publish_state = .Published, created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T00:00:00Z"})
	testing.expect(t, chain_ok, "seed legacy chain")
	h.svc.card_changed = Card_Changed_Hook{ctx = rawptr(h), changed = proc(ctx: rawptr, owner, kind: string) {
		hh := (^Projector_Harness)(ctx)
		append(&hh.changed_kinds, strings.clone(kind))
	}}
	content_service.set_attention_notifier(&h.content_svc, &h.svc.attention_notifier)
}

ph_close :: proc(h: ^Projector_Harness) {
	sqlite.close(&h.conn)
	os.remove(h.path)
	delete(h.changed_kinds)
}

ph_card :: proc(t: ^testing.T, h: ^Projector_Harness, id: domain.Card_ID) -> (domain.Card, bool) {
	c, ok, _ := iface.card_get(&h.cards, id)
	return c, ok
}

ph_conversation :: proc(t: ^testing.T, h: ^Projector_Harness, conv_id, instance_id: string) {
	_, ok, _ := iface.content_save_conversation(&h.content, domain.Chat_Conversation{conversation_id = conv_id, owner_user_id = PH_OWNER, agent_instance_id = instance_id, chain_id = string(PH_CHAIN), created_at = "2026-10-01T00:00:00Z", updated_at = "2026-10-01T00:00:00Z"})
	testing.expect(t, ok, "seed conversation")
}

ph_message :: proc(t: ^testing.T, h: ^Projector_Harness, id, conv_id, instance_id, direction, created_at, metadata: string) {
	_, ok, err := content_service.save_message(&h.content_svc, domain.Chat_Message{message_id = id, conversation_id = conv_id, owner_user_id = PH_OWNER, direction = direction, sender_agent_instance_id = instance_id, body = fmt.tprintf("vault:v2:%s", id), metadata_json = metadata, created_at = created_at})
	testing.expectf(t, ok, "save message: %s", err.message)
}

@(test)
test_projector_message_card_per_instance :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_messages")
	defer ph_close(&h)
	ph_conversation(t, &h, "chat_a", "inst_a")
	ph_conversation(t, &h, "chat_b", "inst_b")
	OPTS :: `{"options":["Yes","No"]}`

	// inst_a: two option messages, then a plain one -> one card, the LATEST
	// option message, the rest counted.
	ph_message(t, &h, "msg_a1", "chat_a", "inst_a", "agent_to_user", "2026-10-01T01:00:00Z", OPTS)
	ph_message(t, &h, "msg_a2", "chat_a", "inst_a", "agent_to_user", "2026-10-01T01:05:00Z", `{"options":["Keep it","Skip it"]}`)
	ph_message(t, &h, "msg_a3", "chat_a", "inst_a", "agent_to_user", "2026-10-01T01:10:00Z", "{}")
	// inst_b: only messages without options -> no card.
	ph_message(t, &h, "msg_b1", "chat_b", "inst_b", "agent_to_user", "2026-10-01T01:00:00Z", "{}")
	ph_message(t, &h, "msg_b2", "chat_b", "inst_b", "agent_to_user", "2026-10-01T01:01:00Z", `{"options":[]}`)

	a, a_ok := ph_card(t, &h, attention_message_card_id("inst_a"))
	testing.expect(t, a_ok, "card for inst_a")
	testing.expect_value(t, a.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, a.kind, domain.CARD_KIND_MESSAGE)
	testing.expect_value(t, a.source_marker, "msg_a2")
	testing.expect_value(t, a.attention_since, "2026-10-01T01:05:00Z")
	testing.expect_value(t, a.title, "vault:v2:msg_a2")
	testing.expect(t, strings.contains(a.details_json, `"options":["Keep it","Skip it"]`), "options of the latest option message")
	testing.expect(t, strings.contains(a.details_json, `"other_unread":2`), "other unread counted")
	testing.expect_value(t, a.action_refs_json, `{"conversation_id":"chat_a","agent_instance_id":"inst_a","message_id":"msg_a2"}`)
	_, b_ok := ph_card(t, &h, attention_message_card_id("inst_b"))
	testing.expect(t, !b_ok, "no card without options")

	// A message card cannot be accepted.
	_, acc_ok, acc_err := accept_card(&h.svc, contracts.Auth_Context{kind = .Session, user_id = string(PH_OWNER)}, a.card_id)
	testing.expect(t, !acc_ok, "message card accept refused")
	testing.expect_value(t, acc_err.code, domain.Error_Code.Conflict)

	// The user replies -> answered -> resolved.
	ph_message(t, &h, "msg_u1", "chat_a", "inst_a", "user_to_agent", "2026-10-01T01:20:00Z", "{}")
	a2, _ := ph_card(t, &h, attention_message_card_id("inst_a"))
	testing.expect_value(t, a2.status, domain.CARD_STATUS_RESOLVED)

	// A new question -> pending again with the new marker.
	ph_message(t, &h, "msg_a4", "chat_a", "inst_a", "agent_to_user", "2026-10-01T01:30:00Z", OPTS)
	a3, _ := ph_card(t, &h, attention_message_card_id("inst_a"))
	testing.expect_value(t, a3.status, domain.CARD_STATUS_PENDING)
	testing.expect_value(t, a3.source_marker, "msg_a4")

	// Reading the conversation retires it.
	_, read_ok, read_err := content_service.mark_read(&h.content_svc, contracts.Auth_Context{kind = .Session, user_id = string(PH_OWNER)}, "chat_a")
	testing.expectf(t, read_ok, "mark read: %s", read_err.message)
	a4, _ := ph_card(t, &h, attention_message_card_id("inst_a"))
	testing.expect_value(t, a4.status, domain.CARD_STATUS_RESOLVED)
}

@(test)
test_projector_reconciliation_repairs_missed_notifications :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_reconcile")
	defer ph_close(&h)
	ph_conversation(t, &h, "chat_r", "inst_r")

	// Sources written straight to the repositories: no notification at all.
	_, _, _ = iface.content_save_message(&h.content, domain.Chat_Message{message_id = "msg_r1", conversation_id = "chat_r", owner_user_id = PH_OWNER, direction = "agent_to_user", sender_agent_instance_id = "inst_r", body = "q", metadata_json = `{"options":["A"]}`, created_at = "2026-10-01T02:00:00Z"})
	// A leftover Hub task card: the Hub task engine is removed, so it retires.
	stale_id := attention_task_card_id("task_stale")
	_, stale_saved, _ := iface.card_create(&h.cards, domain.Card{card_id = stale_id, owner_user_id = PH_OWNER, title = "legacy review", provider = domain.CARD_PROVIDER_TASK_VALIDATION, kind = domain.CARD_KIND_TASK, status = domain.CARD_STATUS_PENDING, operations_json = "[]", guard_json = `{"task_id":"task_stale"}`, created_at = "2026-10-01T02:00:00Z", updated_at = "2026-10-01T02:00:00Z"})
	testing.expect(t, stale_saved, "seed legacy task card")
	stats := reconcile_attention(&h.svc)
	testing.expect_value(t, stats.failed, 0)
	msg, msg_ok := ph_card(t, &h, attention_message_card_id("inst_r"))
	testing.expect(t, msg_ok && msg.status == domain.CARD_STATUS_PENDING, "missing message card created")
	stale, _ := ph_card(t, &h, stale_id)
	testing.expect_value(t, stale.status, domain.CARD_STATUS_RESOLVED)

	// Idempotent: a second sweep changes nothing.
	before := len(h.changed_kinds)
	_ = reconcile_attention(&h.svc)
	testing.expect_value(t, len(h.changed_kinds), before)
}

// Legacy Hub task-validation cards, seeded straight into the card store: the
// Hub task engine (their source) is removed, but rows written before the
// removal still flow through the generic attention listing until reconciled.
Ph_Status :: enum { In_Validation, Completed }
Ph_Task_Seed :: struct { id: string, owner_user_id: domain.User_ID, status: Ph_Status, at: string }

ph_task :: proc(id: string, status: Ph_Status, at: string, reviewers := "") -> Ph_Task_Seed {
	return Ph_Task_Seed{id = id, owner_user_id = PH_OWNER, status = status, at = at}
}

ph_save_task :: proc(t: ^testing.T, h: ^Projector_Harness, seed: Ph_Task_Seed) {
	cid := attention_task_card_id(domain.Task_ID(seed.id))
	status := domain.CARD_STATUS_PENDING if seed.status == .In_Validation else domain.CARD_STATUS_RESOLVED
	if existing, found, _ := iface.card_get(&h.cards, cid); found {
		ok, _ := iface.card_update_status(&h.cards, existing.card_id, status, seed.at)
		testing.expect(t, ok, "update legacy task card")
		notify_card_changed(&h.svc, seed.owner_user_id, domain.CARD_KIND_TASK)
		return
	}
	ops := fmt.tprintf(`[{"op":"task.answer","label":"Answer","args":{"task_id":"%s","attempt_no":0}}]`, seed.id)
	_, ok, err := iface.card_create(&h.cards, domain.Card{card_id = cid, owner_user_id = seed.owner_user_id, title = "vault:v2:task-title", provider = domain.CARD_PROVIDER_TASK_VALIDATION, kind = domain.CARD_KIND_TASK, status = status, operations_json = ops, guard_json = "{}", action_refs_json = fmt.tprintf(`{{"task_id":"%s","chain_id":"%s"}}`, seed.id, PH_CHAIN), attention_since = seed.at, source_marker = seed.at, created_at = seed.at, updated_at = seed.at})
	testing.expectf(t, ok, "seed legacy task card: %s", err.message)
	notify_card_changed(&h.svc, seed.owner_user_id, domain.CARD_KIND_TASK)
}
