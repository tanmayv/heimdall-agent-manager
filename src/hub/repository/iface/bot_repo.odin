package iface

import domain "odin_test:hub/domain"

Bot_Repository :: struct {
	web_activation_get: proc(ctx: rawptr, owner: string) -> (domain.Bot_Web_Activation, bool, domain.Domain_Error),
	web_activation_insert: proc(ctx: rawptr, row: domain.Bot_Web_Activation) -> domain.Domain_Error,
	web_activation_set_enabled: proc(ctx: rawptr, owner: string, enabled: bool, expected_generation: i64) -> (bool, domain.Domain_Error),
	// One indexed query for pending prompts or recently routed actions.
	action_activity: proc(ctx: rawptr, instance_id, routed_since: string) -> (bool, domain.Domain_Error),
	// Web intake atomically creates the local binding and deduplicates the message.
	web_message_store: proc(ctx: rawptr, binding: domain.Channel_Binding, message: domain.Channel_Message, attachments: []domain.Channel_Attachment) -> (domain.Channel_Message, bool, domain.Domain_Error),
	messages_page: proc(ctx: rawptr, owner, bot_id, before: string, limit: int) -> ([]domain.Channel_Message, domain.Domain_Error),

	messages_by_ids: proc(ctx: rawptr, owner, bot_id: string, ids: []string) -> ([]domain.Channel_Message, domain.Domain_Error),

	attachment_set_state: proc(ctx: rawptr, attachment_id: string, from, to: domain.Channel_Attachment_State, updated_at: string) -> (changed: bool, err: domain.Domain_Error),
	attachment_store_artifact: proc(ctx: rawptr, attachment_id, artifact_id, updated_at: string) -> (artifact_id_now: string, err: domain.Domain_Error),
	attachment_get: proc(ctx: rawptr, attachment_id: string) -> (domain.Channel_Attachment, bool, domain.Domain_Error),
	attachments_for_messages: proc(ctx: rawptr, message_ids: []string) -> ([]domain.Channel_Attachment, domain.Domain_Error),
	binding_get:                          proc(
		ctx: rawptr,
		binding_id: string,
	) -> (
		domain.Channel_Binding,
		bool,
		domain.Domain_Error,
	),
	binding_get_active_by_user:           proc(
		ctx: rawptr,
		provider, external_user_id: string,
	) -> (
		domain.Channel_Binding,
		bool,
		domain.Domain_Error,
	),
	bindings_active_for_owner:            proc(
		ctx: rawptr,
		owner_user_id: string,
	) -> (
		[]domain.Channel_Binding,
		domain.Domain_Error,
	),
	binding_set_reengage:                 proc(
		ctx: rawptr,
		binding_id, reengage_sent_at, reengage_error: string,
	) -> domain.Domain_Error,
	push_events_insert:                   proc(
		ctx: rawptr,
		events: []domain.Channel_Push_Event,
	) -> (
		inserted: int,
		err: domain.Domain_Error,
	),
	push_events_pending:                  proc(
		ctx: rawptr,
		provider: string,
		limit: int,
	) -> (
		[]domain.Channel_Push_Event,
		domain.Domain_Error,
	),
	push_batch_commit:                    proc(
		ctx: rawptr,
		rows: []domain.Channel_Message,
		touches: []domain.Channel_Inbound_Touch,
		processed_seqs: []i64,
		processed_at: string,
	) -> (
		inserted: []string,
		err: domain.Domain_Error,
	),
	push_events_purge_processed:          proc(ctx: rawptr, received_before: string) -> (int, domain.Domain_Error),
	messages_mark_replied_binding:        proc(
		ctx: rawptr,
		bot_id, binding_id, replied_at: string,
	) -> (
		count: int,
		err: domain.Domain_Error,
	),
	messages_held:                        proc(
		ctx: rawptr,
		binding_id: string,
	) -> (
		[]domain.Channel_Message,
		domain.Domain_Error,
	),
	message_get_outbound_by_external:     proc(
		ctx: rawptr,
		binding_id, external_message_id: string,
	) -> (
		domain.Channel_Message,
		bool,
		domain.Domain_Error,
	),
	bot_list:                             proc(ctx: rawptr) -> ([]domain.Bot, domain.Domain_Error),
	ctx:                                  rawptr,
	// bots
	bot_insert:                           proc(ctx: rawptr, bot: domain.Bot) -> domain.Domain_Error, // Conflict on UNIQUE(owner)
	bot_get_by_owner:                     proc(
		ctx: rawptr,
		owner_user_id: string,
	) -> (
		domain.Bot,
		bool,
		domain.Domain_Error,
	),
	bot_get:                              proc(ctx: rawptr, bot_id: string) -> (domain.Bot, bool, domain.Domain_Error),
	bot_get_by_instance:                  proc(
		ctx: rawptr,
		agent_instance_id: string,
	) -> (
		domain.Bot,
		bool,
		domain.Domain_Error,
	),
	bot_set_instance:                     proc(
		ctx: rawptr,
		bot_id, agent_instance_id, updated_at: string,
	) -> domain.Domain_Error,
	bot_delete:                           proc(ctx: rawptr, bot_id: string) -> domain.Domain_Error, // cascades candidates
	bot_list_owners_with_open_deliveries: proc(ctx: rawptr) -> ([]string, domain.Domain_Error),
	// placement
	placement_list:                       proc(
		ctx: rawptr,
		bot_id: string,
	) -> (
		[]domain.Bot_Placement_Candidate,
		domain.Domain_Error,
	),
	placement_replace:                    proc(
		ctx: rawptr,
		bot_id: string,
		expected_revision: int,
		rows: []domain.Bot_Placement_Candidate,
		updated_at: string,
	) -> (
		new_revision: int,
		err: domain.Domain_Error,
	), // Conflict if revision moved
	// bindings and pairings
	binding_get_active_by_owner:          proc(
		ctx: rawptr,
		owner_user_id, provider: string,
	) -> (
		domain.Channel_Binding,
		bool,
		domain.Domain_Error,
	),
	binding_get_active_by_chat:           proc(
		ctx: rawptr,
		provider, external_chat_id: string,
	) -> (
		domain.Channel_Binding,
		bool,
		domain.Domain_Error,
	),
	binding_activate:                     proc(
		ctx: rawptr,
		binding: domain.Channel_Binding,
		pairing_code_hash, consumed_at: string,
	) -> (
		revoked_previous: domain.Channel_Binding,
		had_previous: bool,
		err: domain.Domain_Error,
	), // one tx: consume pairing, revoke owner's previous binding, insert
	binding_revoke:                       proc(ctx: rawptr, binding_id, revoked_at: string) -> domain.Domain_Error,
	pairing_consume: proc(ctx: rawptr, code_hash, consumed_at: string) -> (bool, domain.Domain_Error),
	pairing_insert:                       proc(ctx: rawptr, p: domain.Channel_Pairing) -> domain.Domain_Error,
	pairing_get:                          proc(
		ctx: rawptr,
		code_hash: string,
	) -> (
		domain.Channel_Pairing,
		bool,
		domain.Domain_Error,
	),
	pairing_delete_for_owner:             proc(ctx: rawptr, owner_user_id, provider: string) -> domain.Domain_Error,
	// cursor + inbound (one transaction)
	cursor_get:                           proc(ctx: rawptr, provider: string) -> (string, bool, domain.Domain_Error),
	inbound_store_batch:                  proc(
		ctx: rawptr,
		provider: string,
		rows: []domain.Channel_Message,
		next_cursor, now: string,
	) -> (
		inserted: []string,
		err: domain.Domain_Error,
	), // INSERT OR IGNORE on update key, then UPSERT cursor; returns ids actually inserted
	// channel messages
	message_insert_outbound:              proc(ctx: rawptr, msg: domain.Channel_Message) -> domain.Domain_Error,
	message_set_send_result:              proc(
		ctx: rawptr,
		message_id: string,
		state: domain.Channel_Send_State,
		external_message_id, send_error: string,
	) -> domain.Domain_Error,
	messages_pending:                     proc(
		ctx: rawptr,
		bot_id: string,
		limit: int,
	) -> (
		[]domain.Channel_Message,
		domain.Domain_Error,
	), // inbound, replied_at='', oldest first
	messages_mark_read:                   proc(
		ctx: rawptr,
		bot_id: string,
		message_ids: []string,
		read_at: string,
	) -> domain.Domain_Error, // only rows with read_at=''
	messages_mark_replied:                proc(
		ctx: rawptr,
		bot_id, replied_at: string,
	) -> (
		count: int,
		err: domain.Domain_Error,
	), // inbound rows with read_at<>'' AND replied_at=''
	messages_history:                     proc(
		ctx: rawptr,
		bot_id: string,
		limit: int,
	) -> (
		[]domain.Channel_Message,
		domain.Domain_Error,
	), // both directions, newest first
	messages_purge_binding:               proc(ctx: rawptr, binding_id: string) -> domain.Domain_Error,
	messages_purge_older_than:            proc(ctx: rawptr, cutoff: string) -> (int, domain.Domain_Error),
	// deliveries and attempts
	delivery_get_open:                    proc(
		ctx: rawptr,
		bot_id: string,
	) -> (
		domain.Bot_Delivery,
		bool,
		domain.Domain_Error,
	),
	delivery_get:                         proc(
		ctx: rawptr,
		delivery_id: string,
	) -> (
		domain.Bot_Delivery,
		bool,
		domain.Domain_Error,
	),
	delivery_insert:                      proc(ctx: rawptr, d: domain.Bot_Delivery) -> domain.Domain_Error,
	delivery_update:                      proc(
		ctx: rawptr,
		d: domain.Bot_Delivery,
		expected_state: domain.Bot_Delivery_State,
	) -> (
		bool,
		domain.Domain_Error,
	), // CAS on state
	delivery_list_open:                   proc(ctx: rawptr) -> ([]domain.Bot_Delivery, domain.Domain_Error),
	delivery_list_recent:                 proc(
		ctx: rawptr,
		bot_id: string,
		limit: int,
	) -> (
		[]domain.Bot_Delivery,
		domain.Domain_Error,
	),
	attempt_insert:                       proc(ctx: rawptr, a: domain.Bot_Delivery_Attempt) -> domain.Domain_Error,
	attempt_get:                          proc(
		ctx: rawptr,
		attempt_id: string,
	) -> (
		domain.Bot_Delivery_Attempt,
		bool,
		domain.Domain_Error,
	),
	attempt_update:                       proc(
		ctx: rawptr,
		a: domain.Bot_Delivery_Attempt,
		expected_state: domain.Bot_Attempt_State,
	) -> (
		bool,
		domain.Domain_Error,
	), // CAS on state
	attempt_list_for_delivery:            proc(
		ctx: rawptr,
		delivery_id: string,
	) -> (
		[]domain.Bot_Delivery_Attempt,
		domain.Domain_Error,
	),
	attempt_list_open:                    proc(ctx: rawptr) -> ([]domain.Bot_Delivery_Attempt, domain.Domain_Error),
	attempt_list_open_on_bridge:          proc(
		ctx: rawptr,
		bridge_id: string,
	) -> (
		[]domain.Bot_Delivery_Attempt,
		domain.Domain_Error,
	),
}

bot_insert :: proc(repo: ^Bot_Repository, bot: domain.Bot) -> domain.Domain_Error {
	if repo == nil || repo.bot_insert == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bot_insert(repo.ctx, bot)
}

bot_get_by_owner :: proc(repo: ^Bot_Repository, owner_user_id: string) -> (domain.Bot, bool, domain.Domain_Error) {
	if repo == nil || repo.bot_get_by_owner == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bot_get_by_owner(repo.ctx, owner_user_id)
}

bot_get :: proc(repo: ^Bot_Repository, bot_id: string) -> (domain.Bot, bool, domain.Domain_Error) {
	if repo == nil || repo.bot_get == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bot_get(repo.ctx, bot_id)
}

bot_get_by_instance :: proc(
	repo: ^Bot_Repository,
	agent_instance_id: string,
) -> (
	domain.Bot,
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.bot_get_by_instance == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bot_get_by_instance(repo.ctx, agent_instance_id)
}

bot_set_instance :: proc(
	repo: ^Bot_Repository,
	bot_id: string,
	agent_instance_id: string,
	updated_at: string,
) -> domain.Domain_Error {
	if repo == nil || repo.bot_set_instance == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bot_set_instance(repo.ctx, bot_id, agent_instance_id, updated_at)
}

bot_delete :: proc(repo: ^Bot_Repository, bot_id: string) -> domain.Domain_Error {
	if repo == nil || repo.bot_delete == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bot_delete(repo.ctx, bot_id)
}

bot_list_owners_with_open_deliveries :: proc(repo: ^Bot_Repository) -> ([]string, domain.Domain_Error) {
	if repo == nil || repo.bot_list_owners_with_open_deliveries == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bot_list_owners_with_open_deliveries(repo.ctx)
}

placement_list :: proc(
	repo: ^Bot_Repository,
	bot_id: string,
) -> (
	[]domain.Bot_Placement_Candidate,
	domain.Domain_Error,
) {
	if repo == nil || repo.placement_list == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.placement_list(repo.ctx, bot_id)
}

placement_replace :: proc(
	repo: ^Bot_Repository,
	bot_id: string,
	expected_revision: int,
	rows: []domain.Bot_Placement_Candidate,
	updated_at: string,
) -> (
	new_revision: int,
	err: domain.Domain_Error,
) {
	if repo == nil || repo.placement_replace == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.placement_replace(repo.ctx, bot_id, expected_revision, rows, updated_at)
}

binding_get_active_by_owner :: proc(
	repo: ^Bot_Repository,
	owner_user_id: string,
	provider: string,
) -> (
	domain.Channel_Binding,
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.binding_get_active_by_owner == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.binding_get_active_by_owner(repo.ctx, owner_user_id, provider)
}

binding_get_active_by_chat :: proc(
	repo: ^Bot_Repository,
	provider: string,
	external_chat_id: string,
) -> (
	domain.Channel_Binding,
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.binding_get_active_by_chat == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.binding_get_active_by_chat(repo.ctx, provider, external_chat_id)
}

binding_activate :: proc(
	repo: ^Bot_Repository,
	binding: domain.Channel_Binding,
	pairing_code_hash: string,
	consumed_at: string,
) -> (
	revoked_previous: domain.Channel_Binding,
	had_previous: bool,
	err: domain.Domain_Error,
) {
	if repo == nil || repo.binding_activate == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.binding_activate(repo.ctx, binding, pairing_code_hash, consumed_at)
}

binding_revoke :: proc(repo: ^Bot_Repository, binding_id: string, revoked_at: string) -> domain.Domain_Error {
	if repo == nil || repo.binding_revoke == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.binding_revoke(repo.ctx, binding_id, revoked_at)
}

pairing_insert :: proc(repo: ^Bot_Repository, p: domain.Channel_Pairing) -> domain.Domain_Error {
	if repo == nil || repo.pairing_insert == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.pairing_insert(repo.ctx, p)
}

pairing_get :: proc(repo: ^Bot_Repository, code_hash: string) -> (domain.Channel_Pairing, bool, domain.Domain_Error) {
	if repo == nil || repo.pairing_get == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.pairing_get(repo.ctx, code_hash)
}

pairing_delete_for_owner :: proc(
	repo: ^Bot_Repository,
	owner_user_id: string,
	provider: string,
) -> domain.Domain_Error {
	if repo == nil || repo.pairing_delete_for_owner == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.pairing_delete_for_owner(repo.ctx, owner_user_id, provider)
}

cursor_get :: proc(repo: ^Bot_Repository, provider: string) -> (string, bool, domain.Domain_Error) {
	if repo == nil || repo.cursor_get == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.cursor_get(repo.ctx, provider)
}

inbound_store_batch :: proc(
	repo: ^Bot_Repository,
	provider: string,
	rows: []domain.Channel_Message,
	next_cursor: string,
	now: string,
) -> (
	inserted: []string,
	err: domain.Domain_Error,
) {
	if repo == nil || repo.inbound_store_batch == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.inbound_store_batch(repo.ctx, provider, rows, next_cursor, now)
}

message_insert_outbound :: proc(repo: ^Bot_Repository, msg: domain.Channel_Message) -> domain.Domain_Error {
	if repo == nil || repo.message_insert_outbound == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.message_insert_outbound(repo.ctx, msg)
}

message_set_send_result :: proc(
	repo: ^Bot_Repository,
	message_id: string,
	state: domain.Channel_Send_State,
	external_message_id: string,
	send_error: string,
) -> domain.Domain_Error {
	if repo == nil || repo.message_set_send_result == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.message_set_send_result(repo.ctx, message_id, state, external_message_id, send_error)
}

messages_pending :: proc(
	repo: ^Bot_Repository,
	bot_id: string,
	limit: int,
) -> (
	[]domain.Channel_Message,
	domain.Domain_Error,
) {
	if repo == nil || repo.messages_pending == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_pending(repo.ctx, bot_id, limit)
}

messages_mark_read :: proc(
	repo: ^Bot_Repository,
	bot_id: string,
	message_ids: []string,
	read_at: string,
) -> domain.Domain_Error {
	if repo == nil || repo.messages_mark_read == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_mark_read(repo.ctx, bot_id, message_ids, read_at)
}

messages_mark_replied :: proc(
	repo: ^Bot_Repository,
	bot_id: string,
	replied_at: string,
) -> (
	count: int,
	err: domain.Domain_Error,
) {
	if repo == nil || repo.messages_mark_replied == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_mark_replied(repo.ctx, bot_id, replied_at)
}

messages_history :: proc(
	repo: ^Bot_Repository,
	bot_id: string,
	limit: int,
) -> (
	[]domain.Channel_Message,
	domain.Domain_Error,
) {
	if repo == nil || repo.messages_history == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_history(repo.ctx, bot_id, limit)
}

messages_purge_binding :: proc(repo: ^Bot_Repository, binding_id: string) -> domain.Domain_Error {
	if repo == nil || repo.messages_purge_binding == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_purge_binding(repo.ctx, binding_id)
}

messages_purge_older_than :: proc(repo: ^Bot_Repository, cutoff: string) -> (int, domain.Domain_Error) {
	if repo == nil || repo.messages_purge_older_than == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_purge_older_than(repo.ctx, cutoff)
}

delivery_get_open :: proc(repo: ^Bot_Repository, bot_id: string) -> (domain.Bot_Delivery, bool, domain.Domain_Error) {
	if repo == nil || repo.delivery_get_open == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.delivery_get_open(repo.ctx, bot_id)
}

delivery_get :: proc(repo: ^Bot_Repository, delivery_id: string) -> (domain.Bot_Delivery, bool, domain.Domain_Error) {
	if repo == nil || repo.delivery_get == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.delivery_get(repo.ctx, delivery_id)
}

delivery_insert :: proc(repo: ^Bot_Repository, d: domain.Bot_Delivery) -> domain.Domain_Error {
	if repo == nil || repo.delivery_insert == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.delivery_insert(repo.ctx, d)
}

delivery_update :: proc(
	repo: ^Bot_Repository,
	d: domain.Bot_Delivery,
	expected_state: domain.Bot_Delivery_State,
) -> (
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.delivery_update == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.delivery_update(repo.ctx, d, expected_state)
}

delivery_list_open :: proc(repo: ^Bot_Repository) -> ([]domain.Bot_Delivery, domain.Domain_Error) {
	if repo == nil || repo.delivery_list_open == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.delivery_list_open(repo.ctx)
}

delivery_list_recent :: proc(
	repo: ^Bot_Repository,
	bot_id: string,
	limit: int,
) -> (
	[]domain.Bot_Delivery,
	domain.Domain_Error,
) {
	if repo == nil || repo.delivery_list_recent == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.delivery_list_recent(repo.ctx, bot_id, limit)
}

attempt_insert :: proc(repo: ^Bot_Repository, a: domain.Bot_Delivery_Attempt) -> domain.Domain_Error {
	if repo == nil || repo.attempt_insert == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attempt_insert(repo.ctx, a)
}

attempt_get :: proc(
	repo: ^Bot_Repository,
	attempt_id: string,
) -> (
	domain.Bot_Delivery_Attempt,
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.attempt_get == nil do return {}, {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attempt_get(repo.ctx, attempt_id)
}

attempt_update :: proc(
	repo: ^Bot_Repository,
	a: domain.Bot_Delivery_Attempt,
	expected_state: domain.Bot_Attempt_State,
) -> (
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.attempt_update == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attempt_update(repo.ctx, a, expected_state)
}

attempt_list_for_delivery :: proc(
	repo: ^Bot_Repository,
	delivery_id: string,
) -> (
	[]domain.Bot_Delivery_Attempt,
	domain.Domain_Error,
) {
	if repo == nil || repo.attempt_list_for_delivery == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attempt_list_for_delivery(repo.ctx, delivery_id)
}

attempt_list_open :: proc(repo: ^Bot_Repository) -> ([]domain.Bot_Delivery_Attempt, domain.Domain_Error) {
	if repo == nil || repo.attempt_list_open == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attempt_list_open(repo.ctx)
}

attempt_list_open_on_bridge :: proc(
	repo: ^Bot_Repository,
	bridge_id: string,
) -> (
	[]domain.Bot_Delivery_Attempt,
	domain.Domain_Error,
) {
	if repo == nil || repo.attempt_list_open_on_bridge == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attempt_list_open_on_bridge(repo.ctx, bridge_id)
}

pairing_consume :: proc(repo: ^Bot_Repository, code_hash, consumed_at: string) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.pairing_consume == nil do return false, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.pairing_consume(repo.ctx, code_hash, consumed_at)
}

bot_list :: proc(repo: ^Bot_Repository) -> ([]domain.Bot, domain.Domain_Error) {
	if repo == nil || repo.bot_list == nil do return nil, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bot_list(repo.ctx)
}

binding_get :: proc(repo: ^Bot_Repository, binding_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error) {
	if repo == nil || repo.binding_get == nil do return {}, false, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.binding_get(repo.ctx, binding_id)
}

binding_get_active_by_user :: proc(
	repo: ^Bot_Repository,
	provider, external_user_id: string,
) -> (
	domain.Channel_Binding,
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.binding_get_active_by_user == nil do return {}, false, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.binding_get_active_by_user(repo.ctx, provider, external_user_id)
}

bindings_active_for_owner :: proc(
	repo: ^Bot_Repository,
	owner_user_id: string,
) -> (
	[]domain.Channel_Binding,
	domain.Domain_Error,
) {
	if repo == nil || repo.bindings_active_for_owner == nil do return nil, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.bindings_active_for_owner(repo.ctx, owner_user_id)
}

binding_set_reengage :: proc(
	repo: ^Bot_Repository,
	binding_id, reengage_sent_at, reengage_error: string,
) -> domain.Domain_Error {
	if repo == nil || repo.binding_set_reengage == nil do return domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.binding_set_reengage(repo.ctx, binding_id, reengage_sent_at, reengage_error)
}

push_events_insert :: proc(
	repo: ^Bot_Repository,
	events: []domain.Channel_Push_Event,
) -> (
	inserted: int,
	err: domain.Domain_Error,
) {
	if repo == nil || repo.push_events_insert == nil do return 0, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.push_events_insert(repo.ctx, events)
}

push_events_pending :: proc(
	repo: ^Bot_Repository,
	provider: string,
	limit: int,
) -> (
	[]domain.Channel_Push_Event,
	domain.Domain_Error,
) {
	if repo == nil || repo.push_events_pending == nil do return nil, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.push_events_pending(repo.ctx, provider, limit)
}

push_batch_commit :: proc(
	repo: ^Bot_Repository,
	rows: []domain.Channel_Message,
	touches: []domain.Channel_Inbound_Touch,
	processed_seqs: []i64,
	processed_at: string,
) -> (
	inserted: []string,
	err: domain.Domain_Error,
) {
	if repo == nil || repo.push_batch_commit == nil do return nil, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.push_batch_commit(repo.ctx, rows, touches, processed_seqs, processed_at)
}

push_events_purge_processed :: proc(repo: ^Bot_Repository, received_before: string) -> (int, domain.Domain_Error) {
	if repo == nil || repo.push_events_purge_processed == nil do return 0, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.push_events_purge_processed(repo.ctx, received_before)
}

messages_mark_replied_binding :: proc(
	repo: ^Bot_Repository,
	bot_id, binding_id, replied_at: string,
) -> (
	count: int,
	err: domain.Domain_Error,
) {
	if repo == nil || repo.messages_mark_replied_binding == nil do return 0, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_mark_replied_binding(repo.ctx, bot_id, binding_id, replied_at)
}

messages_held :: proc(repo: ^Bot_Repository, binding_id: string) -> ([]domain.Channel_Message, domain.Domain_Error) {
	if repo == nil || repo.messages_held == nil do return nil, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_held(repo.ctx, binding_id)
}

message_get_outbound_by_external :: proc(
	repo: ^Bot_Repository,
	binding_id, external_message_id: string,
) -> (
	domain.Channel_Message,
	bool,
	domain.Domain_Error,
) {
	if repo == nil || repo.message_get_outbound_by_external == nil do return {}, false, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.message_get_outbound_by_external(repo.ctx, binding_id, external_message_id)
}

attachments_for_messages :: proc(repo: ^Bot_Repository, message_ids: []string) -> ([]domain.Channel_Attachment, domain.Domain_Error) {
	if repo == nil || repo.attachments_for_messages == nil do return {}, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attachments_for_messages(repo.ctx, message_ids)
}

attachment_get :: proc(repo: ^Bot_Repository, attachment_id: string) -> (domain.Channel_Attachment, bool, domain.Domain_Error) {
	if repo == nil || repo.attachment_get == nil do return {}, false, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attachment_get(repo.ctx, attachment_id)
}

attachment_store_artifact :: proc(repo: ^Bot_Repository, attachment_id, artifact_id, updated_at: string) -> (artifact_id_now: string, err: domain.Domain_Error) {
	if repo == nil || repo.attachment_store_artifact == nil do return "", domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attachment_store_artifact(repo.ctx, attachment_id, artifact_id, updated_at)
}

attachment_set_state :: proc(repo: ^Bot_Repository, attachment_id: string, from, to: domain.Channel_Attachment_State, updated_at: string) -> (changed: bool, err: domain.Domain_Error) {
	if repo == nil || repo.attachment_set_state == nil do return false, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.attachment_set_state(repo.ctx, attachment_id, from, to, updated_at)
}

web_message_store :: proc(repo: ^Bot_Repository, binding: domain.Channel_Binding, message: domain.Channel_Message, attachments: []domain.Channel_Attachment) -> (domain.Channel_Message, bool, domain.Domain_Error) {
	if repo == nil || repo.web_message_store == nil do return {}, false, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.web_message_store(repo.ctx, binding, message, attachments)
}
messages_by_ids :: proc(repo: ^Bot_Repository, owner, bot_id: string, ids: []string) -> ([]domain.Channel_Message, domain.Domain_Error) {
	if repo == nil || repo.messages_by_ids == nil do return nil, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_by_ids(repo.ctx, owner, bot_id, ids)
}

messages_page :: proc(repo: ^Bot_Repository, owner, bot_id, before: string, limit: int) -> ([]domain.Channel_Message, domain.Domain_Error) {
	if repo == nil || repo.messages_page == nil do return nil, domain.domain_error(.Internal_Error, "bot repository is not configured")
	return repo.messages_page(repo.ctx, owner, bot_id, before, limit)
}

bot_action_activity :: proc(repo: ^Bot_Repository, instance_id, routed_since: string) -> (bool, domain.Domain_Error) {
 if repo == nil || repo.action_activity == nil do return false, domain.domain_error(.Internal_Error, "bot action activity lookup is not configured")
 return repo.action_activity(repo.ctx, instance_id, routed_since)
}


// Web activation snapshots belong to the caller. A missing row means no
// activation has occurred, not just that the current flag is off.
bot_web_activation_get :: proc(repo: ^Bot_Repository, owner: string) -> (domain.Bot_Web_Activation, bool, domain.Domain_Error) {
	if repo == nil || repo.web_activation_get == nil do return {}, false, domain.domain_error(.Internal_Error, "bot web activation repository is not configured")
	return repo.web_activation_get(repo.ctx, owner)
}
bot_web_activation_insert :: proc(repo: ^Bot_Repository, row: domain.Bot_Web_Activation) -> domain.Domain_Error {
	if repo == nil || repo.web_activation_insert == nil do return domain.domain_error(.Internal_Error, "bot web activation repository is not configured")
	return repo.web_activation_insert(repo.ctx, row)
}
bot_web_activation_set_enabled :: proc(repo: ^Bot_Repository, owner: string, enabled: bool, expected_generation: i64) -> (bool, domain.Domain_Error) {
	if repo == nil || repo.web_activation_set_enabled == nil do return false, domain.domain_error(.Internal_Error, "bot web activation repository is not configured")
	return repo.web_activation_set_enabled(repo.ctx, owner, enabled, expected_generation)
}
