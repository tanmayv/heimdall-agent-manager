package bots

import placement "odin_test:hub/service/placement"

import "core:encoding/json"
import "core:sync"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import provider_service "odin_test:hub/service/provider"
import project_service "odin_test:hub/service/project"
import events "odin_test:hub/service/events"
import channel "odin_test:hub/service/channel"
import content "odin_test:hub/service/content"

Bots_Service :: struct {
	channel_vault_directory: ^iface.Vault_Directory_Repository,
	channel_vault_exchange: Channel_Vault_Exchange,
	canonical_telegram: bool,
	canonical_whatsapp_owner: string,
	canonical_content: ^content.Content_Service,
 placement: ^placement.Service,
	ui_origin: string,
	media_send_budget_ms, media_min_call_ms: i64,
	repo: ^iface.Bot_Repository,
	uow_factory: ^iface.Unit_Of_Work_Factory,
	event_bus: ^events.User_Event_Bus,
	experiments: ^iface.Experiment_Repository,
	// Per-account WhatsApp entitlement (invite-only); zero value is permissive.
	entitlements: domain.Entitlement_Lookup,
	agents: ^agent_service.Agent_Service,
	providers: ^provider_service.Provider_Service,
	bridges: ^iface.Bridge_Repository,
	registry: ^project_service.Bridge_Runtime_Registry,
	command_sink: ^project_service.Bridge_Command_Sink,
	adapter: ^channel.Channel_Adapter,
	whatsapp: ^channel.Channel_Adapter,
	clock: ^platform.Clock,
	ids: ^platform.ID_Generator,
	timers: Bot_Timer_Config,
	mutex: sync.Mutex,
	web_activation_mutex: sync.Mutex,
	legacy_fence_mutex: sync.Mutex,
	reengage_mutex: sync.Mutex,
	boot_unix_ms: i64,
	hello_queue: [dynamic]string,
	last_waiting_recheck_ms: i64,
	last_idle_check_ms, last_retention_ms: i64,
	notices: [dynamic]Bot_Notice,
}

canonical_channel_enabled :: proc(s: ^Bots_Service, provider: string, owner := "") -> bool {
	switch provider {
	case domain.CHANNEL_PROVIDER_TELEGRAM: return s.canonical_telegram
	case domain.CHANNEL_PROVIDER_WHATSAPP:
		return s.canonical_whatsapp_owner!="" && (owner=="" || s.canonical_whatsapp_owner==owner)
	}
	return false
}

// WhatsApp sometimes rotates the address form in the signed inbound event.
// Only the same stable provider user may use that alias. It never replaces
// the immutable address used for an outbound reply.
canonical_channel_sender_matches :: proc(provider, address, user: string, event: channel.Inbound) -> bool {
	return user!="" && event.external_user_id==user && event.external_chat_id!="" &&
		(address==event.external_chat_id || provider==domain.CHANNEL_PROVIDER_WHATSAPP)
}

bots_adapter :: proc(s: ^Bots_Service, provider: string) -> ^channel.Channel_Adapter {
	switch provider {
	case domain.CHANNEL_PROVIDER_WEB: return &bots_web_adapter
	case domain.CHANNEL_PROVIDER_TELEGRAM: return s.adapter
	case domain.CHANNEL_PROVIDER_WHATSAPP: return s.whatsapp
	}
	return nil
}

bots_provider_uses_user_fallback :: proc(provider: string) -> bool {
	return provider == domain.CHANNEL_PROVIDER_WHATSAPP
}

// Repository snapshots returned here belong to the caller.
bots_find_binding :: proc(s: ^Bots_Service, provider, external_chat_id, external_user_id: string) -> (domain.Channel_Binding, bool, domain.Domain_Error) {
	binding, found, err := iface.binding_get_active_by_chat(s.repo, provider, external_chat_id)
	if found || err.code != .None || external_user_id == "" || !bots_provider_uses_user_fallback(provider) do return binding, found, err
	domain.channel_binding_destroy(&binding)
	return iface.binding_get_active_by_user(s.repo, provider, external_user_id)
}

bots_get :: proc(s: ^Bots_Service, owner: string) -> (domain.Bot, domain.Domain_Error) {
	if err := bots_gate_error(s.experiments, owner); err.code != .None do return {}, err
	bot, found, err := iface.bot_get_by_owner(s.repo, owner)
	if err.code != .None do return {}, err
	if !found do return {}, bots_detail_error(.Not_Found, "bot_not_found")
	return bot, {}
}

bots_create :: proc(s: ^Bots_Service, auth: contracts.Auth_Context) -> domain.Domain_Error {
	sync.mutex_lock(&s.web_activation_mutex)
	defer sync.mutex_unlock(&s.web_activation_mutex)
	// Agent service mutations return mixed borrowed/owned snapshots and use
	// request-scoped scratch. Keep those allocations in the caller's temp arena.
	context.allocator = context.temp_allocator
	if err := bots_gate_error(s.experiments, auth.user_id); err.code != .None do return err
	// The database UNIQUE(owner) serializes concurrent creates. Never hold the
	// delivery mutex across agent calls.
	existing, found, get_err := iface.bot_get_by_owner(s.repo, auth.user_id)
	defer domain.bot_destroy(&existing)
	if get_err.code != .None do return get_err
	if found do return bots_detail_error(.Conflict, "bot_exists")
	bot_id := platform.generate_id(s.ids, "bot_")
	agent, created, err := agent_service.create_agent(s.agents, auth, {name = "Ninjy bot", slug = bot_id, template_id = domain.TEMPLATE_BOT_ID, has_template_id = true, permission_mode = "yolo"})
	if err.code != .None do return err
	if !created do return domain.domain_error(.Internal_Error, "could not create bot agent")
	now := platform.clock_now(s.clock)
	insert_err := iface.bot_insert(s.repo, {bot_id = bot_id, owner_user_id = auth.user_id, agent_id = agent.agent_id, display_name = "Ninjy bot", placement_revision = 1, created_at = now, updated_at = now})
	if insert_err.code != .None {
		_, _, archive_err := agent_service.archive_agent(s.agents, auth, agent.agent_id)
		if archive_err.code != .None do return archive_err
		if insert_err.code == .Conflict do return bots_detail_error(.Conflict, "bot_exists")
		return insert_err
	}
	return {}
}

Bot_Advanced_View :: struct {
	conversation_id: string `json:"conversation_id,omitempty"`,
	agent_instance_id, bridge_id, bridge_label, provider, model, runtime_status: string,
}
Bot_Telegram_View :: struct {
	configured: bool,
	bot_username: string,
	binding: json.Value,
}
Bot_Held_Reply_View :: struct {message_id, body, created_at: string}
Bot_WhatsApp_View :: struct {
	configured: bool,
	// Effective whatsapp_enabled entitlement (REQ-WAI-3). Display only: pairing
	// and inbound enforce it independently.
	enabled: bool,
	phone_display: string,
	binding: json.Value,
	window_open, reengage_sent: bool,
	reengage_error: string,
	held_replies: []Bot_Held_Reply_View,
}
Bot_View :: struct {
	bot_id, display_name, status, status_detail: string,
	telegram: Bot_Telegram_View,
	whatsapp: Bot_WhatsApp_View,
	placement_revision: int,
	advanced: Bot_Advanced_View,
}

// JSON is owned by the caller. All repository snapshots are released here.
bots_view_json :: proc(s: ^Bots_Service, owner: string) -> (string, domain.Domain_Error) {
	bot, err := bots_get(s, owner)
	if err.code != .None do return "", err
	defer domain.bot_destroy(&bot)
	view := Bot_View{bot_id = bot.bot_id, display_name = bot.display_name, status = "new", placement_revision = bot.placement_revision}
	// Settings still reads this resource for bot identity and placement. Once
	// cut over it must not disclose held text or advertise old pairings/runtime.
	if fence := bots_legacy_guard(s, owner); fence.code != .None {
		if fence.code != .Conflict do return "", fence
		view.telegram.binding = json.Null(nil)
		state, live, state_err := iface.bot_web_activation_get(s.repo,owner)
		defer domain.bot_web_activation_destroy(&state)
		if state_err.code!=.None do return "",state_err
		view.whatsapp.binding = json.Null(nil)
		view.whatsapp.held_replies = make([]Bot_Held_Reply_View,0,context.temp_allocator)
		if live && state.enabled {
			if s.canonical_telegram && s.adapter!=nil {
				binding, _, get_err := canonical_binding_view(s,state,"telegram")
				if get_err.code!=.None do return "",get_err
				view.telegram.configured=true
				view.telegram.binding=binding
			}
			if canonical_channel_enabled(s,"whatsapp",owner) && s.whatsapp!=nil {
				entitled, entitlement_err := bots_channel_entitled(s,"whatsapp",owner)
				if entitlement_err.code!=.None do return "",entitlement_err
				view.whatsapp.configured=true
				view.whatsapp.enabled=entitled
				if entitled {
					binding, window_open, get_err := canonical_binding_view(s,state,"whatsapp")
					if get_err.code!=.None do return "",get_err
					view.whatsapp.binding=binding
					view.whatsapp.window_open=window_open
				}
			}
		}
		return bots_encode_view(view)
	}
	identity: channel.Identity
	identity_err: channel.Channel_Error
	if s.adapter != nil {
		view.telegram.configured = true
		if s.adapter.identity != nil {
			identity, identity_err = s.adapter.identity(s.adapter.ctx)
			view.telegram.bot_username = identity.bot_username
		}
	}
	binding, bound, binding_err := iface.binding_get_active_by_owner(s.repo, owner, "telegram")
	defer domain.channel_binding_destroy(&binding)
	if binding_err.code != .None do return "", binding_err
	view.telegram.binding = json.Null(nil)
	if bound {
		obj := make(json.Object, context.temp_allocator)
		obj["state"] = "active"
		obj["display"] = binding.external_display
		obj["connected_at"] = binding.created_at
		view.telegram.binding = obj
	}
	view.whatsapp.binding = json.Null(nil)
	view.whatsapp.held_replies = make([]Bot_Held_Reply_View, 0, context.temp_allocator)
	if s.whatsapp != nil {
		view.whatsapp.configured = true
		// A lookup failure keeps the connect path visible; pairing re-checks and
		// refuses with whatsapp_invite_only, so the hint never grants access.
		entitled, entitlement_err := bots_channel_entitled(s, domain.CHANNEL_PROVIDER_WHATSAPP, owner)
		view.whatsapp.enabled = entitled || entitlement_err.code != .None
		wa_identity, wa_err := s.whatsapp.identity(s.whatsapp.ctx)
		if wa_err.kind == .None do view.whatsapp.phone_display = strings.concatenate({"+", wa_identity.bot_username}, context.temp_allocator)
	}
	wa_binding, wa_bound, wa_binding_err := iface.binding_get_active_by_owner(s.repo, owner, "whatsapp")
	defer domain.channel_binding_destroy(&wa_binding)
	if wa_binding_err.code != .None do return "", wa_binding_err
	held: []domain.Channel_Message
	defer {for &m in held do domain.channel_message_destroy(&m); delete(held)}
	if wa_bound {
		obj := make(json.Object, context.temp_allocator)
		obj["state"], obj["display"], obj["connected_at"] = "active", wa_binding.external_display, wa_binding.created_at
		view.whatsapp.binding = obj
		view.whatsapp.window_open = !bots_window_closed(s.whatsapp, wa_binding, bots_stamp_ms(platform.clock_now(s.clock)))
		view.whatsapp.reengage_sent = wa_binding.reengage_sent_at != ""
		view.whatsapp.reengage_error = wa_binding.reengage_error
		held_err: domain.Domain_Error
		held, held_err = iface.messages_held(s.repo, wa_binding.binding_id)
		if held_err.code != .None do return "", held_err
		view.whatsapp.held_replies = make([]Bot_Held_Reply_View, min(20, len(held)), context.temp_allocator)
		for m, i in held[:len(view.whatsapp.held_replies)] do view.whatsapp.held_replies[i] = {m.message_id, m.body, m.created_at}
	}
	inst: domain.Agent_Instance
	defer domain.agent_instance_destroy(&inst)
	if bot.agent_instance_id != "" {
		found: bool
		inst, found, err = iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
		if err.code != .None do return "", err
		if found && string(inst.owner_user_id) == owner && inst.agent_id == bot.agent_id {
			view.advanced = {conversation_id = inst.conversation_id, agent_instance_id = inst.agent_instance_id, bridge_id = inst.bridge_id, provider = inst.provider, model = inst.model, runtime_status = inst.runtime_status}
			view.status = "sleeping"
			switch inst.runtime_status {
			case "launching", "starting": view.status = "starting"
			case "running", "idle", "busy": view.status = "ready"
			}
		}
	}
	bridge: domain.Bridge
	defer domain.bridge_destroy(&bridge)
	if view.advanced.bridge_id != "" {
		bridge, _, err = iface.bridge_get_bridge(s.bridges, view.advanced.bridge_id)
		if err.code != .None do return "", err
		view.advanced.bridge_label = bridge.label
	}
	delivery, open, delivery_err := iface.delivery_get_open(s.repo, bot.bot_id)
	defer domain.bot_delivery_destroy(&delivery)
	if delivery_err.code != .None do return "", delivery_err
	if open && delivery.state == .Waiting {view.status = "waiting_for_machine"; view.status_detail = delivery.waiting_reason}
	if open && delivery.state == .Dispatched do view.status = "working"
	if !open {
		recent, recent_err := iface.delivery_list_recent(s.repo, bot.bot_id, 1)
		defer {for &d in recent do domain.bot_delivery_destroy(&d); delete(recent)}
		if recent_err.code != .None do return "", recent_err
		if len(recent) > 0 && recent[0].state == .Abandoned && (recent[0].finish_reason == "all_tried" || recent[0].finish_reason == "max_rounds") {
			messages, msg_err := iface.messages_history(s.repo, bot.bot_id, -1)
			defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
			if msg_err.code != .None do return "", msg_err
			new_inbound := false
			for m in messages do if m.direction == .Inbound && m.created_at > recent[0].finished_at do new_inbound = true
			if !new_inbound do view.status_detail = "gave_up"
		}
	}
	return bots_encode_view(view)
}

canonical_binding_view :: proc(s: ^Bots_Service,state: domain.Bot_Web_Activation,provider: string) -> (json.Value,bool,domain.Domain_Error) {
	b, bound, err := iface.binding_get_active_by_owner(s.repo,state.owner_user_id,provider)
	defer domain.channel_binding_destroy(&b)
	if err.code!=.None || !bound do return json.Null(nil),false,err
	grant, granted, grant_err := iface.bot_channel_conversion_binding_get(s.repo,b.binding_id)
	if grant_err.code!=.None || !granted || grant.activation_generation!=state.generation do return json.Null(nil),false,grant_err
	obj := make(json.Object,context.temp_allocator)
	obj["state"]="active"
	obj["display"]=strings.clone(b.external_display,context.temp_allocator)
	obj["connected_at"]=strings.clone(b.created_at,context.temp_allocator)
	return obj,!bots_window_closed(bots_adapter(s,provider),b,bots_now_ms(s)),{}
}

bots_encode_view :: proc(view: Bot_View) -> (string, domain.Domain_Error) {
	data, marshal_err := json.marshal(view)
	if marshal_err != nil do return "", domain.domain_error(.Internal_Error, "could not encode bot")
	return string(data), {}
}

bots_delete :: proc(s: ^Bots_Service, auth: contracts.Auth_Context) -> domain.Domain_Error {
	sync.mutex_lock(&s.web_activation_mutex)
	defer sync.mutex_unlock(&s.web_activation_mutex)
	if gate := bots_gate_error(s.experiments, auth.user_id); gate.code != .None do return gate
	activation, activated, activation_err := iface.bot_web_activation_get(s.repo, auth.user_id)
	defer domain.bot_web_activation_destroy(&activation)
	if activation_err.code != .None do return activation_err
	if activated do return bots_detail_error(.Conflict, "bot_requires_shared_chat")
	// stop/archive use the same request-scratch convention as create_agent.
	context.allocator = context.temp_allocator
	bot, err := bots_get(s, auth.user_id)
	if err.code != .None do return err
	defer domain.bot_destroy(&bot)
	now := platform.clock_now(s.clock)
	for provider in ([]string{"telegram", "whatsapp", "web"}) {
		if e := bots_disconnect_for_reason(s, auth.user_id, provider, true, "bot_deleted"); e.code != .None && e.code != .Not_Found do return e
	}
	sync.mutex_lock(&s.mutex)
	delivery, open, delivery_err := iface.delivery_get_open(s.repo, bot.bot_id)
	if delivery_err.code == .None && open {
		attempts, attempt_err := iface.attempt_list_for_delivery(s.repo, delivery.delivery_id)
		if attempt_err.code != .None {delivery_err = attempt_err} else {
			for &a in attempts {
				if domain.bot_attempt_state_open(a.state) {
					expected := a.state
					updated := a
					updated.state, updated.finished_at = .Cancelled, now
					_, delivery_err = iface.attempt_update(s.repo, updated, expected)
					if delivery_err.code != .None do break
				}
			}
		}
		for &a in attempts do domain.bot_delivery_attempt_destroy(&a)
		delete(attempts)
		if delivery_err.code == .None {
			expected := delivery.state
			delivery.state = .Abandoned
			// Do not overwrite owned snapshot strings before destroying them.
			updated := delivery
			updated.finish_reason, updated.finished_at, updated.updated_at = "bot_deleted", now, now
			_, delivery_err = iface.delivery_update(s.repo, updated, expected)
		}
	}
	domain.bot_delivery_destroy(&delivery)
	sync.mutex_unlock(&s.mutex)
	if delivery_err.code != .None do return delivery_err
	if bot.agent_instance_id != "" {
		inst, found, inst_err := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
		defer domain.agent_instance_destroy(&inst)
		if inst_err.code != .None do return inst_err
		if found && (inst.runtime_status == "running" || inst.runtime_status == "idle" || inst.runtime_status == "busy" || inst.runtime_status == "starting" || inst.runtime_status == "launching" || inst.runtime_status == "blocked" || inst.runtime_status == "stopping") {
			_, _, stop_err := agent_service.stop_instance(s.agents, auth, inst.agent_instance_id, {reason = "bot_deleted"})
			if stop_err.code != .None do return stop_err
		}
	}
	_, _, archive_err := agent_service.archive_agent(s.agents, auth, bot.agent_id)
	if archive_err.code != .None do return archive_err
	// Purge every binding represented in this bot's history, including revoked ones.
	messages, msg_err := iface.messages_history(s.repo, bot.bot_id, -1)
	defer {for &m in messages do domain.channel_message_destroy(&m); delete(messages)}
	if msg_err.code != .None do return msg_err
	seen := make(map[string]bool)
	defer delete(seen)
	for m in messages {
		if seen[m.binding_id] do continue
		seen[m.binding_id] = true
		if e := iface.messages_purge_binding(s.repo, m.binding_id); e.code != .None do return e
	}
	for provider in ([]string{"telegram", "whatsapp", "web"}) {
		if e := iface.pairing_delete_for_owner(s.repo, auth.user_id, provider); e.code != .None do return e
	}
	return iface.bot_delete(s.repo, bot.bot_id)
}

bots_put_placement :: proc(s: ^Bots_Service, owner: string, expected_revision: int, rows: []domain.Bot_Placement_Candidate) -> (int, domain.Domain_Error) {
	bot, err := bots_get(s, owner)
	if err.code != .None do return 0, err
	defer domain.bot_destroy(&bot)
	if e := bots_validate_placement(s, owner, rows); e.code != .None do return 0, e
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	now := platform.clock_now(s.clock)
	revision, replace_err := iface.placement_replace(s.repo, bot.bot_id, expected_revision, rows, now)
	if replace_err.code == .Conflict do return 0, bots_detail_error(.Conflict, "placement_revision_changed")
	if replace_err.code != .None do return 0, replace_err
	d, open, delivery_err := iface.delivery_get_open(s.repo, bot.bot_id)
	defer domain.bot_delivery_destroy(&d)
	if delivery_err.code != .None do return 0, delivery_err
	if open && d.state == .Waiting {
		_ = bots_wake_locked(s, d, now)
	}
	return revision, delivery_err
}

bots_web_adapter := channel.Channel_Adapter{provider = domain.CHANNEL_PROVIDER_WEB, send_text = channel.web_send_text}
