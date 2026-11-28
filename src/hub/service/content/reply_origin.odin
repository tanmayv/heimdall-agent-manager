package content

import "core:encoding/json"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// Reply origin (R7). A reply answers the user->agent inputs the agent consumed
// after the conversation's reply watermark (the previous reply's consumption
// point). Consumption is durable (chat_input_consumptions): ACP inline
// delivery, or the agent's own `chat read` that marks messages read. Nothing
// here is held in memory, so a restarted Hub computes the same answer.
//
// The result is stored only under the reply's metadata_json.reply_origin
// (G7); the watermark points at the reply that carries it.

REPLY_ORIGIN_METADATA_KEY :: "reply_origin"

// note_agent_consumed records that the agent itself consumed these messages
// (kind INPUT_CONSUMED_DELIVERED or INPUT_CONSUMED_READ). Rows that are not
// user->agent messages of the instance's conversation are ignored, and only
// the first consumption of a message counts.
note_agent_consumed :: proc(s: ^Content_Service, auth: contracts.Auth_Context, instance_id: string, message_ids: []string, kind: string) -> domain.Domain_Error {
	if len(message_ids) == 0 || !iface.content_reply_origin_supported(s.content) do return {}
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" || auth.agent_instance_id != instance_id do return domain.domain_error(.Forbidden, "instance token is required")
	uow, begun, uerr := iface.unit_of_work_begin(s.uow_factory)
	if !begun do return uerr
	committed := false
	defer if !committed do iface.unit_of_work_rollback(&uow)
	local := s^
	if uow.repos != nil do local.content = &uow.repos.content
	c, found, cerr := get_conversation_by_instance(&local, auth, instance_id)
	if !found do return cerr
	now := platform.clock_now(s.clock)
	for id in message_ids {
		if err := iface.content_record_input_consumption(local.content, c.owner_user_id, c.conversation_id, id, kind, now); err.code != .None do return err
	}
	ok, err := iface.unit_of_work_commit(&uow)
	if !ok do return err
	committed = true
	return {}
}

// reply_origin_resolve is the pure rule. consumed: inputs consumed after the
// watermark; previous: the last reply's origin (have_previous=false when none).
reply_origin_resolve :: proc(consumed: []domain.Input_Consumption, previous: domain.Reply_Origin, have_previous, has_channel: bool) -> domain.Reply_Origin {
	if len(consumed) > 0 {
		ids := make([]string, len(consumed), context.temp_allocator)
		origin := consumed[0].origin
		single := true
		for row, i in consumed {
			ids[i] = row.message_id
			if row.origin != origin do single = false
		}
		if single do return {answered_message_ids=ids, origin=origin, route_status=domain.REPLY_ROUTE_ROUTED, source=domain.REPLY_SOURCE_CONSUMED}
		return {answered_message_ids=ids, origin="", route_status=domain.REPLY_ROUTE_AMBIGUOUS, source=domain.REPLY_SOURCE_CONSUMED}
	}
	// Nothing new consumed: a later reply keeps answering the same input.
	if have_previous && len(previous.answered_message_ids) > 0 {
		inherited := previous
		inherited.source = domain.REPLY_SOURCE_INHERITED
		return inherited
	}
	// No input at all: never guess a channel.
	status := domain.REPLY_ROUTE_AMBIGUOUS if has_channel else domain.REPLY_ROUTE_NONE
	return {answered_message_ids=make([]string, 0, context.temp_allocator), origin="", route_status=status, source=domain.REPLY_SOURCE_NONE}
}

// reply_origin_validate_reply_to checks a --reply-to id against the reply's
// owner, conversation and direction.
reply_origin_validate_reply_to :: proc(repo: ^iface.Content_Repository, c: domain.Chat_Conversation, reply_to: string) -> (string, domain.Domain_Error) {
	m, found, err := iface.content_get_message(repo, reply_to)
	if err.code != .None && err.code != .Not_Found do return "", err
	// Another owner's message is reported exactly like an unknown id.
	if !found || m.owner_user_id != c.owner_user_id do return "", domain.domain_error(.Not_Found, "reply-to message not found")
	if m.conversation_id != c.conversation_id do return "", domain.domain_error(.Validation_Failed, "reply-to message belongs to another conversation")
	if m.direction != "user_to_agent" do return "", domain.domain_error(.Validation_Failed, "reply-to must name a message the user sent to this agent")
	return iface.content_message_origin(repo, reply_to)
}

// reply_origin_previous reads the origin recorded on the watermark's reply.
reply_origin_previous :: proc(repo: ^iface.Content_Repository, w: domain.Reply_Watermark) -> (domain.Reply_Origin, bool) {
	if w.reply_message_id == "" do return {}, false
	m, found, _ := iface.content_get_message(repo, w.reply_message_id)
	if !found do return {}, false
	holder: struct { reply_origin: domain.Reply_Origin }
	if json.unmarshal_string(m.metadata_json, &holder, allocator = context.temp_allocator) != nil do return {}, false
	if holder.reply_origin.route_status == "" do return {}, false
	return holder.reply_origin, true
}

// reply_origin_record computes the reply's origin and advances the watermark.
// It must run inside the reply's unit of work (repo = the uow repository), so
// two racing replies never both claim the same consumption.
reply_origin_record :: proc(repo: ^iface.Content_Repository, c: domain.Chat_Conversation, reply_message_id, reply_to, now: string) -> (domain.Reply_Origin, domain.Domain_Error) {
	owner := c.owner_user_id
	w, have_w, werr := iface.content_get_reply_watermark(repo, owner, c.conversation_id)
	if werr.code != .None do return {}, werr
	consumed, lerr := iface.content_list_input_consumptions(repo, owner, c.conversation_id, w.through_seq)
	if lerr.code != .None do return {}, lerr
	result: domain.Reply_Origin
	if reply_to != "" {
		origin, verr := reply_origin_validate_reply_to(repo, c, reply_to)
		if verr.code != .None do return {}, verr
		ids := make([]string, 1, context.temp_allocator)
		ids[0] = reply_to
		result = {answered_message_ids=ids, origin=origin, route_status=domain.REPLY_ROUTE_EXPLICIT, source=domain.REPLY_SOURCE_REPLY_TO}
	} else {
		previous: domain.Reply_Origin
		have_previous := false
		if have_w do previous, have_previous = reply_origin_previous(repo, w)
		has_channel := false
		if len(consumed) == 0 && !(have_previous && len(previous.answered_message_ids) > 0) {
			hc, herr := iface.content_conversation_has_channel(repo, owner, c.conversation_id)
			if herr.code != .None do return {}, herr
			has_channel = hc
		}
		result = reply_origin_resolve(consumed, previous, have_previous, has_channel)
	}
	// Every reply moves the watermark to its own consumption point, including
	// an explicit --reply-to: what the agent consumed so far is behind it.
	through := w.through_seq
	if len(consumed) > 0 do through = consumed[len(consumed)-1].seq
	next := domain.Reply_Watermark{conversation_id=c.conversation_id, owner_user_id=string(owner), through_seq=through, reply_message_id=reply_message_id, updated_at=now}
	if err := iface.content_advance_reply_watermark(repo, next, w.through_seq); err.code != .None do return {}, err
	return result, {}
}

// reply_origin_metadata merges reply_origin into the reply's metadata object,
// replacing any agent-supplied value of that key.
reply_origin_metadata :: proc(metadata_json: string, origin: domain.Reply_Origin) -> (string, domain.Domain_Error) {
	obj: json.Object
	if metadata_json != "" {
		parsed, perr := json.parse_string(metadata_json, allocator = context.temp_allocator)
		if perr != nil do return "", domain.domain_error(.Validation_Failed, "message metadata must be a JSON object")
		existing, is_obj := parsed.(json.Object)
		if !is_obj do return "", domain.domain_error(.Validation_Failed, "message metadata must be a JSON object")
		obj = existing
	} else {
		obj = make(json.Object, allocator = context.temp_allocator)
	}
	ids := origin.answered_message_ids
	if ids == nil do ids = make([]string, 0, context.temp_allocator)
	answered := make(json.Array, len(ids), context.temp_allocator)
	for id, i in ids do answered[i] = json.String(id)
	value := make(json.Object, allocator = context.temp_allocator)
	value["answered_message_ids"] = answered
	value["origin"] = json.String(origin.origin)
	value["route_status"] = json.String(origin.route_status)
	value["source"] = json.String(origin.source)
	obj[REPLY_ORIGIN_METADATA_KEY] = value
	raw, merr := json.marshal(obj, {sort_maps_by_key = true}, allocator = context.temp_allocator)
	if merr != nil do return "", domain.domain_error(.Internal_Error, "cannot encode reply origin")
	return string(raw), {}
}

// reply_origin_applies: system rows (start-success banners) are not replies.
reply_origin_applies :: proc(message_type: string) -> bool {
	return message_type != "system"
}

// save_agent_reply persists an agent->user message. A reply records its
// origin and advances the watermark in the same unit of work as the row.
save_agent_reply :: proc(s: ^Content_Service, c: domain.Chat_Conversation, m: domain.Chat_Message, reply_to, now: string) -> (domain.Chat_Message, bool, domain.Domain_Error) {
	if !reply_origin_applies(m.message_type) {
		if reply_to != "" do return {}, false, domain.domain_error(.Validation_Failed, "reply-to applies only to replies")
		return save_message(s, m)
	}
	if !iface.content_reply_origin_supported(s.content) || s.uow_factory == nil {
		if reply_to != "" do return {}, false, domain.domain_error(.Internal_Error, "reply origin is not configured")
		return save_message(s, m)
	}
	uow, begun, uerr := iface.unit_of_work_begin(s.uow_factory)
	if !begun do return {}, false, uerr
	committed := false
	defer if !committed do iface.unit_of_work_rollback(&uow)
	repo := s.content
	if uow.repos != nil do repo = &uow.repos.content
	origin, oerr := reply_origin_record(repo, c, m.message_id, reply_to, now)
	if oerr.code != .None do return {}, false, oerr
	row := m
	metadata, merr := reply_origin_metadata(m.metadata_json, origin)
	if merr.code != .None do return {}, false, merr
	row.metadata_json = metadata
	saved, ok, err := iface.content_save_message(repo, row)
	if !ok do return {}, false, err
	if done, cerr := iface.unit_of_work_commit(&uow); !done do return {}, false, cerr
	committed = true
	// Attention reads the committed row, outside the transaction.
	notify_message_attention(s, saved)
	return saved, true, {}
}
