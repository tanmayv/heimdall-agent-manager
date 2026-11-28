package domain

BOT_ID_PREFIX :: "bot_"
CHANNEL_BINDING_ID_PREFIX :: "chb_"
CHANNEL_MESSAGE_ID_PREFIX :: "chm_"
CHANNEL_ATTACHMENT_ID_PREFIX :: "cha_"
BOT_DELIVERY_ID_PREFIX :: "bdl_"
BOT_ATTEMPT_ID_PREFIX :: "bda_"
CHANNEL_PROVIDER_WEB :: "web"
CHANNEL_PROVIDER_TELEGRAM :: "telegram"
CHANNEL_PROVIDER_WHATSAPP :: "whatsapp"
BOT_PLACEMENT_ANY :: "*"
BOT_MAX_PLACEMENT_CANDIDATES :: 32

Bot :: struct {
	bot_id, owner_user_id, agent_id, agent_instance_id, display_name: string,
	placement_revision:                                               int,
	created_at, updated_at:                                           string,
}

// The canonical web identity is pinned after the first opt-in.
Bot_Web_Activation :: struct {
	owner_user_id, bot_id, agent_instance_id, conversation_id: string,
	enabled: bool,
	generation: i64,
}

bot_web_activation_destroy :: proc(row: ^Bot_Web_Activation) {
	delete(row.owner_user_id)
	delete(row.bot_id)
	delete(row.agent_instance_id)
	delete(row.conversation_id)
	row^ = {}
}

// Payload-free evidence. Only canonical pairing, input persistence and the
// trusted turn router can write these records, respectively.
Bot_Channel_Fresh_Binding :: struct {
	binding_id: string,
	activation_generation, binding_generation: i64,
	pairing_update_key: string,
}
Bot_Channel_Origin :: struct {
	inbound_message_id, binding_id, provider_update_key, external_message_id: string,
}
bot_channel_origin_destroy :: proc(row: ^Bot_Channel_Origin) {
	delete(row.inbound_message_id)
	delete(row.binding_id)
	delete(row.provider_update_key)
	delete(row.external_message_id)
	row^ = {}
}

Bot_Channel_Reply_Source :: struct {
	origin: Bot_Channel_Origin,
	source_proof: string,
}
bot_channel_reply_source_destroy :: proc(row: ^Bot_Channel_Reply_Source) {
	bot_channel_origin_destroy(&row.origin)
	delete(row.source_proof)
	row^ = {}
}

Bot_Placement_Tier :: enum {
	Preferred,
	Allowed,
}

Bot_Placement_Candidate :: struct {
	position:                   int,
	bridge_id, provider, model: string, // each may be BOT_PLACEMENT_ANY
	tier:                       Bot_Placement_Tier,
}

Channel_Binding_State :: enum {
	Active,
	Revoked,
}

Channel_Binding :: struct {
	binding_id, owner_user_id, bot_id, provider:          string,
	external_chat_id, external_user_id, external_display: string,
	state:                                                Channel_Binding_State,
	created_at, revoked_at:                               string,
	last_inbound_at, reengage_sent_at, reengage_error:    string,
}

Channel_Pairing :: struct {
	code_hash, owner_user_id, bot_id, provider: string,
	created_at, expires_at, consumed_at:        string,
}

Channel_Direction :: enum {
	Inbound,
	Outbound,
}
Channel_Send_State :: enum {
	None,
	Pending,
	Sent,
	Failed,
	Held,
}

Channel_Message :: struct {
	message_id, binding_id, owner_user_id, bot_id:  string,
	direction:                                      Channel_Direction,
	provider_update_key, external_message_id, body: string,
	body_purged:                                    bool,
	send_state:                                     Channel_Send_State,
	send_error:                                     string,
	created_at, read_at, replied_at:                string,
	action_ids_json: string,
	attachment: Channel_Attachment,
}

Bot_Delivery_State :: enum {
	Pending,
	Dispatched,
	Waiting,
	Acted,
	Abandoned,
}

Bot_Delivery :: struct {
	delivery_id, bot_id, owner_user_id, through_message_id: string,
	state:                                                  Bot_Delivery_State,
	round:                                                  int,
	waiting_reason, waiting_notice_at, finish_reason:       string,
	created_at, updated_at, finished_at:                    string,
}

Bot_Attempt_State :: enum {
	Relocating,
	Sent,
	Accepted,
	Acted,
	Exhausted,
	Busy,
	Disconnected,
	Deadline,
	Cancelled,
}

Bot_Delivery_Attempt :: struct {
	attempt_id, delivery_id:                                                        string,
	round:                                                                          int,
	bridge_id:                                                                      string,
	state:                                                                          Bot_Attempt_State,
	relocation_key, candidates_json, report_json:                                   string,
	report_seq:                                                                     int,
	sent_at, accepted_at, last_report_at, disconnected_at, created_at, finished_at: string,
}

bot_attempt_state_open :: proc(s: Bot_Attempt_State) -> bool {
	return s == .Relocating || s == .Sent || s == .Accepted
}
bot_delivery_state_open :: proc(s: Bot_Delivery_State) -> bool {
	return s == .Pending || s == .Dispatched || s == .Waiting
}

bot_placement_tier_text :: proc(value: Bot_Placement_Tier) -> string {
	switch value {
	case .Preferred:
		return "preferred"
	case .Allowed:
		return "allowed"
	}
	return ""
}

bot_placement_tier_from_text :: proc(value: string) -> (Bot_Placement_Tier, bool) {
	switch value {
	case "preferred":
		return .Preferred, true
	case "allowed":
		return .Allowed, true
	}
	return {}, false
}

channel_binding_state_text :: proc(value: Channel_Binding_State) -> string {
	switch value {
	case .Active:
		return "active"
	case .Revoked:
		return "revoked"
	}
	return ""
}

channel_binding_state_from_text :: proc(value: string) -> (Channel_Binding_State, bool) {
	switch value {
	case "active":
		return .Active, true
	case "revoked":
		return .Revoked, true
	}
	return {}, false
}

channel_direction_text :: proc(value: Channel_Direction) -> string {
	switch value {
	case .Inbound:
		return "inbound"
	case .Outbound:
		return "outbound"
	}
	return ""
}

channel_direction_from_text :: proc(value: string) -> (Channel_Direction, bool) {
	switch value {
	case "inbound":
		return .Inbound, true
	case "outbound":
		return .Outbound, true
	}
	return {}, false
}

channel_send_state_text :: proc(value: Channel_Send_State) -> string {
	switch value {
	case .None:
		return ""
	case .Pending:
		return "pending"
	case .Sent:
		return "sent"
	case .Failed:
		return "failed"
	case .Held:
		return "held"
	}
	return ""
}

channel_send_state_from_text :: proc(value: string) -> (Channel_Send_State, bool) {
	switch value {
	case "":
		return .None, true
	case "pending":
		return .Pending, true
	case "sent":
		return .Sent, true
	case "failed":
		return .Failed, true
	case "held":
		return .Held, true
	}
	return {}, false
}

bot_delivery_state_text :: proc(value: Bot_Delivery_State) -> string {
	switch value {
	case .Pending:
		return "pending"
	case .Dispatched:
		return "dispatched"
	case .Waiting:
		return "waiting"
	case .Acted:
		return "acted"
	case .Abandoned:
		return "abandoned"
	}
	return ""
}

bot_delivery_state_from_text :: proc(value: string) -> (Bot_Delivery_State, bool) {
	switch value {
	case "pending":
		return .Pending, true
	case "dispatched":
		return .Dispatched, true
	case "waiting":
		return .Waiting, true
	case "acted":
		return .Acted, true
	case "abandoned":
		return .Abandoned, true
	}
	return {}, false
}

bot_attempt_state_text :: proc(value: Bot_Attempt_State) -> string {
	switch value {
	case .Relocating:
		return "relocating"
	case .Sent:
		return "sent"
	case .Accepted:
		return "accepted"
	case .Acted:
		return "acted"
	case .Exhausted:
		return "exhausted"
	case .Busy:
		return "busy"
	case .Disconnected:
		return "disconnected"
	case .Deadline:
		return "deadline"
	case .Cancelled:
		return "cancelled"
	}
	return ""
}

bot_attempt_state_from_text :: proc(value: string) -> (Bot_Attempt_State, bool) {
	switch value {
	case "relocating":
		return .Relocating, true
	case "sent":
		return .Sent, true
	case "accepted":
		return .Accepted, true
	case "acted":
		return .Acted, true
	case "exhausted":
		return .Exhausted, true
	case "busy":
		return .Busy, true
	case "disconnected":
		return .Disconnected, true
	case "deadline":
		return .Deadline, true
	case "cancelled":
		return .Cancelled, true
	}
	return {}, false
}

bot_destroy :: proc(value: ^Bot) {
	if value == nil do return
	if len(value.bot_id) > 0 do delete(value.bot_id)
	if len(value.owner_user_id) > 0 do delete(value.owner_user_id)
	if len(value.agent_id) > 0 do delete(value.agent_id)
	if len(value.agent_instance_id) > 0 do delete(value.agent_instance_id)
	if len(value.display_name) > 0 do delete(value.display_name)
	if len(value.created_at) > 0 do delete(value.created_at)
	if len(value.updated_at) > 0 do delete(value.updated_at)
	value^ = {}
}

bot_placement_candidate_destroy :: proc(value: ^Bot_Placement_Candidate) {
	if value == nil do return
	if len(value.bridge_id) > 0 do delete(value.bridge_id)
	if len(value.provider) > 0 do delete(value.provider)
	if len(value.model) > 0 do delete(value.model)
	value^ = {}
}

channel_binding_destroy :: proc(value: ^Channel_Binding) {
	if value == nil do return
	if len(value.binding_id) > 0 do delete(value.binding_id)
	if len(value.owner_user_id) > 0 do delete(value.owner_user_id)
	if len(value.bot_id) > 0 do delete(value.bot_id)
	if len(value.provider) > 0 do delete(value.provider)
	if len(value.external_chat_id) > 0 do delete(value.external_chat_id)
	if len(value.external_user_id) > 0 do delete(value.external_user_id)
	if len(value.external_display) > 0 do delete(value.external_display)
	if len(value.created_at) > 0 do delete(value.created_at)
	if len(value.revoked_at) > 0 do delete(value.revoked_at)
	if len(value.last_inbound_at) > 0 do delete(value.last_inbound_at)
	if len(value.reengage_sent_at) > 0 do delete(value.reengage_sent_at)
	if len(value.reengage_error) > 0 do delete(value.reengage_error)
	value^ = {}
}

channel_pairing_destroy :: proc(value: ^Channel_Pairing) {
	if value == nil do return
	if len(value.code_hash) > 0 do delete(value.code_hash)
	if len(value.owner_user_id) > 0 do delete(value.owner_user_id)
	if len(value.bot_id) > 0 do delete(value.bot_id)
	if len(value.provider) > 0 do delete(value.provider)
	if len(value.created_at) > 0 do delete(value.created_at)
	if len(value.expires_at) > 0 do delete(value.expires_at)
	if len(value.consumed_at) > 0 do delete(value.consumed_at)
	value^ = {}
}

channel_message_destroy :: proc(value: ^Channel_Message) {
	if value == nil do return
	if len(value.message_id) > 0 do delete(value.message_id)
	if len(value.binding_id) > 0 do delete(value.binding_id)
	if len(value.owner_user_id) > 0 do delete(value.owner_user_id)
	if len(value.bot_id) > 0 do delete(value.bot_id)
	if len(value.provider_update_key) > 0 do delete(value.provider_update_key)
	if len(value.external_message_id) > 0 do delete(value.external_message_id)
	if len(value.body) > 0 do delete(value.body)
	if len(value.send_error) > 0 do delete(value.send_error)
	if len(value.created_at) > 0 do delete(value.created_at)
	if len(value.read_at) > 0 do delete(value.read_at)
	if len(value.replied_at) > 0 do delete(value.replied_at)
	delete(value.action_ids_json)
	channel_attachment_destroy(&value.attachment)
	value^ = {}
}

bot_delivery_destroy :: proc(value: ^Bot_Delivery) {
	if value == nil do return
	if len(value.delivery_id) > 0 do delete(value.delivery_id)
	if len(value.bot_id) > 0 do delete(value.bot_id)
	if len(value.owner_user_id) > 0 do delete(value.owner_user_id)
	if len(value.through_message_id) > 0 do delete(value.through_message_id)
	if len(value.waiting_reason) > 0 do delete(value.waiting_reason)
	if len(value.waiting_notice_at) > 0 do delete(value.waiting_notice_at)
	if len(value.finish_reason) > 0 do delete(value.finish_reason)
	if len(value.created_at) > 0 do delete(value.created_at)
	if len(value.updated_at) > 0 do delete(value.updated_at)
	if len(value.finished_at) > 0 do delete(value.finished_at)
	value^ = {}
}

bot_delivery_attempt_destroy :: proc(value: ^Bot_Delivery_Attempt) {
	if value == nil do return
	if len(value.attempt_id) > 0 do delete(value.attempt_id)
	if len(value.delivery_id) > 0 do delete(value.delivery_id)
	if len(value.bridge_id) > 0 do delete(value.bridge_id)
	if len(value.relocation_key) > 0 do delete(value.relocation_key)
	if len(value.candidates_json) > 0 do delete(value.candidates_json)
	if len(value.report_json) > 0 do delete(value.report_json)
	if len(value.sent_at) > 0 do delete(value.sent_at)
	if len(value.accepted_at) > 0 do delete(value.accepted_at)
	if len(value.last_report_at) > 0 do delete(value.last_report_at)
	if len(value.disconnected_at) > 0 do delete(value.disconnected_at)
	if len(value.created_at) > 0 do delete(value.created_at)
	if len(value.finished_at) > 0 do delete(value.finished_at)
	value^ = {}
}

Channel_Push_Kind :: enum {
	Text,
	Start,
	Disconnect,
	Unsupported,
	Delivery_Failed,
	Media,
}
Channel_Push_Event :: struct {
	seq:                                                                           i64,
	provider, event_key:                                                           string,
	kind:                                                                          Channel_Push_Kind,
	external_chat_id, external_user_id, external_message_id, sender_display, body: string,
	provider_code:                                                                 int,
	provider_time, received_at, processed_at:                                      string,
	media_kind: Channel_Media_Kind,
	media_ref, media_name, media_mime: string,
	media_size: i64,
}

// One binding touched by inbound; at is provider_time, or now when empty.
Channel_Inbound_Touch :: struct {
	binding_id, at: string,
}
channel_push_kind_text :: proc(k: Channel_Push_Kind) -> string {
	switch k {
	case .Text:
		return "text"
	case .Start:
		return "start"
	case .Disconnect:
		return "disconnect"
	case .Unsupported:
		return "unsupported"
	case .Delivery_Failed:
		return "delivery_failed"
	case .Media:
		return "media"
	}
	return ""
}
channel_push_kind_from_text :: proc(s: string) -> (Channel_Push_Kind, bool) {
	switch s {
	case "text":
		return .Text, true
	case "start":
		return .Start, true
	case "disconnect":
		return .Disconnect, true
	case "unsupported":
		return .Unsupported, true
	case "delivery_failed":
		return .Delivery_Failed, true
	case "media":
		return .Media, true
	}
	return {}, false
}
channel_push_event_destroy :: proc(e: ^Channel_Push_Event) {
	if e == nil do return
	if len(e.provider) > 0 do delete(e.provider)
	if len(e.event_key) > 0 do delete(e.event_key)
	if len(e.external_chat_id) > 0 do delete(e.external_chat_id)
	if len(e.external_user_id) > 0 do delete(e.external_user_id)
	if len(e.external_message_id) > 0 do delete(e.external_message_id)
	if len(e.sender_display) > 0 do delete(e.sender_display)
	if len(e.body) > 0 do delete(e.body)
	if len(e.provider_time) > 0 do delete(e.provider_time)
	if len(e.received_at) > 0 do delete(e.received_at)
	if len(e.processed_at) > 0 do delete(e.processed_at)
	if len(e.media_ref) > 0 do delete(e.media_ref)
	if len(e.media_name) > 0 do delete(e.media_name)
	if len(e.media_mime) > 0 do delete(e.media_mime)
	e^ = {}
}

Channel_Media_Kind :: enum { None, Image, Document, Voice, Audio }
Channel_Attachment_State :: enum { Pending, Stored, Too_Large, Unavailable, Native, Link }

channel_media_kind_text :: proc(value: Channel_Media_Kind) -> string {
	switch value {
	case .None: return ""
	case .Image: return "image"
	case .Document: return "document"
	case .Voice: return "voice"
	case .Audio: return "audio"
	}
	return ""
}
channel_media_kind_from_text :: proc(value: string) -> (Channel_Media_Kind, bool) {
	switch value {
	case "": return .None, true
	case "image": return .Image, true
	case "document": return .Document, true
	case "voice": return .Voice, true
	case "audio": return .Audio, true
	}
	return {}, false
}

channel_attachment_state_text :: proc(value: Channel_Attachment_State) -> string {
	switch value {
	case .Pending: return "pending"
	case .Stored: return "stored"
	case .Too_Large: return "too_large"
	case .Unavailable: return "unavailable"
	case .Native: return "native"
	case .Link: return "link"
	}
	return ""
}
channel_attachment_state_from_text :: proc(value: string) -> (Channel_Attachment_State, bool) {
	switch value {
	case "pending": return .Pending, true
	case "stored": return .Stored, true
	case "too_large": return .Too_Large, true
	case "unavailable": return .Unavailable, true
	case "native": return .Native, true
	case "link": return .Link, true
	}
	return {}, false
}

Channel_Attachment :: struct {
	attachment_id, message_id, binding_id, owner_user_id, bot_id: string,
	direction: Channel_Direction,
	kind: Channel_Media_Kind,
	file_ref, name, mime: string,
	size_bytes: i64,
	artifact_id: string,
	state: Channel_Attachment_State,
	created_at, updated_at: string,
}
channel_attachment_destroy :: proc(a: ^Channel_Attachment) {
	if a == nil do return
	if len(a.attachment_id) > 0 do delete(a.attachment_id)
	if len(a.message_id) > 0 do delete(a.message_id)
	if len(a.binding_id) > 0 do delete(a.binding_id)
	if len(a.owner_user_id) > 0 do delete(a.owner_user_id)
	if len(a.bot_id) > 0 do delete(a.bot_id)
	if len(a.file_ref) > 0 do delete(a.file_ref)
	if len(a.name) > 0 do delete(a.name)
	if len(a.mime) > 0 do delete(a.mime)
	if len(a.artifact_id) > 0 do delete(a.artifact_id)
	if len(a.created_at) > 0 do delete(a.created_at)
	if len(a.updated_at) > 0 do delete(a.updated_at)
	a^ = {}
}

Bot_Channel_Reply_Job :: struct {reply_message_id,owner_user_id,provider: string}

Bot_Channel_Feedback :: struct {input_id,binding_id,owner,chat_id,external_message_id,reaction: string}
