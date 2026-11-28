package bots

import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import content "odin_test:hub/service/content"

Canonical_Lifecycle_Guard :: struct {
	service: ^Bots_Service,
	owner, conversation, instance: string,
	generation: i64,
}

canonical_lifecycle_state :: proc(g: ^Canonical_Lifecycle_Guard) -> (domain.Agent_Instance, domain.Domain_Error) {
	state, found, err := iface.bot_web_activation_get(g.service.repo,g.owner)
	defer domain.bot_web_activation_destroy(&state)
	if err.code != .None do return {},err
	if !found || !state.enabled || state.generation != g.generation || state.conversation_id != g.conversation || state.agent_instance_id != g.instance {
		return {},bots_detail_error(.Conflict,"bot_generation_inactive")
	}
	inst, exists, inst_err := iface.agent_get_instance(g.service.agents.agents,g.instance)
	if inst_err.code != .None do return {},inst_err
	if !exists || string(inst.owner_user_id) != g.owner || inst.conversation_id != g.conversation {
		domain.agent_instance_destroy(&inst)
		return {},bots_detail_error(.Not_Found,"bot_instance_missing")
	}
	return inst,{}
}

canonical_start_guard :: proc(raw: rawptr) -> domain.Domain_Error {
	g := (^Canonical_Lifecycle_Guard)(raw)
	inst, err := canonical_lifecycle_state(g)
	if err.code != .None do return err
	defer domain.agent_instance_destroy(&inst)
	if inst.stopped_by == agent.STOPPED_BY_USER || agent.stop_reason_is_user(agent.Stop_Reason(inst.stop_reason)) {
		err := bots_detail_error(.Conflict,"agent_manually_stopped")
		err.cause = contracts.MESSAGE_DELIVERY_REASON_MANUALLY_STOPPED
		return err
	}
	return check_web_runtime_policy(g.service,inst,inst.bridge_id,inst.provider,inst.model,inst.model)
}

canonical_start_pending :: proc(err: domain.Domain_Error) -> content.Message_Delivery {
	if err.cause == contracts.MESSAGE_DELIVERY_REASON_MANUALLY_STOPPED do return {.Pending,err.cause}
	#partial switch err.code {
	case .Bridge_Offline: return {.Pending,contracts.MESSAGE_DELIVERY_REASON_BRIDGE_OFFLINE}
	case .Provider_Unavailable: return {.Pending,contracts.MESSAGE_DELIVERY_REASON_PROVIDER_UNAVAILABLE}
	case .Forbidden, .Not_Found, .Conflict: return {.Pending,contracts.MESSAGE_DELIVERY_REASON_PLACEMENT_UNAVAILABLE}
	}
	return {.Pending,contracts.MESSAGE_DELIVERY_REASON_AGENT_START_FAILED}
}

// Only an accepted, committed canonical user message calls this seam. Neither
// provider retries nor write-receipt replays cause another launch or notice.
deliver_canonical_message :: proc(raw: rawptr, svc: ^content.Content_Service, auth: contracts.Auth_Context, m: domain.Chat_Message, generation: i64) -> content.Message_Delivery {
	s := (^Bots_Service)(raw)
	g := Canonical_Lifecycle_Guard{s,string(m.owner_user_id),m.conversation_id,m.sender_agent_instance_id,generation}
	inst, _, started, err := agent.ensure_running(s.agents,auth,g.instance,.User_Message,&g,canonical_start_guard)
	defer domain.agent_instance_destroy(&inst)
	pending: Maybe(content.Message_Delivery)
	if !started {
		pending = canonical_start_pending(err)
	} else if inst.startup_status != "ready" || inst.runtime_status=="launching" || inst.runtime_status=="starting" {
		// The shared readiness hook will re-admit the unchanged unread IDs.
		pending = content.Message_Delivery{.Pending,contracts.MESSAGE_DELIVERY_REASON_AGENT_STARTING}
	} else if guard_err := canonical_start_guard(&g); guard_err.code != .None {
		pending = canonical_start_pending(guard_err)
	}
	result, _ := content.deliver_user_message(svc,auth,m.conversation_id,m,pending,&inst)
	return result
}

// Both explicit starts and the Ready transition of a fenced relocation use
// the same Runtime inbox. Nothing is reinserted into the canonical chat.
replay_canonical_unread :: proc(s: ^Bots_Service, svc: ^content.Content_Service, snapshot: domain.Agent_Instance) {
	if s==nil || svc==nil || s.agents==nil || snapshot.conversation_id=="" do return
	context.allocator = context.temp_allocator
	state, found, err := iface.bot_web_activation_get(s.repo,string(snapshot.owner_user_id))
	if err.code != .None || !found || !state.enabled || state.agent_instance_id != snapshot.agent_instance_id || state.conversation_id != snapshot.conversation_id do return
	g := Canonical_Lifecycle_Guard{s,string(snapshot.owner_user_id),snapshot.conversation_id,snapshot.agent_instance_id,state.generation}
	inst, live_err := canonical_lifecycle_state(&g)
	if live_err.code != .None || !content.message_delivery_assignment_matches(inst,snapshot) ||
	   !agent.runtime_expected_active(inst.runtime_status) || inst.runtime_status=="stopping" || inst.startup_status!="ready" ||
	   inst.stopped_by!="" || inst.stop_reason!="" {return}
	if idle, _ := agent.reconfiguration_require_idle(s.agents,inst.agent_instance_id); !idle do return
	if policy := check_web_runtime_policy(s,inst,inst.bridge_id,inst.provider,inst.model,inst.model); policy.code != .None do return
	if ledger_err := content.reconcile_unread_for_pty(svc,inst); ledger_err.code != .None do return
	c, ok, _ := iface.content_get_conversation(svc.content,inst.conversation_id)
	if !ok || c.owner_user_id != inst.owner_user_id || c.agent_instance_id != inst.agent_instance_id do return
	// ACP receives a fetch edge from the normal notice. PTY coalesces a notice
	// for its inbox; one unread canonical identity is sufficient in both cases.
	rows, list_err := iface.content_list_agent_inbox_messages(svc.content,c.conversation_id,c.owner_user_id,inst.agent_instance_id,true,true,false,false,100,"",true,inst.runtime_transport=="acp")
	if list_err.code != .None do return
	for m in rows {
		if m.direction!="user_to_agent" || m.message_type=="previous_context" do continue
		delivery, delivered, delivery_err := iface.content_get_input_delivery(svc.content,m.message_id)
		if delivery_err.code != .None do return
		if delivered && (delivery.state=="delivered" || delivery.state=="discarded" || delivery.state=="dispatching" || delivery.agent_read_at!="") do continue
		_, _ = content.notify_agent_message_checked(svc,c,"user_to_agent","user",m.message_id,"User",&inst)
		break
	}
}

Canonical_Idle_Guard :: struct {
	canonical: Canonical_Lifecycle_Guard,
	expected: ^domain.Agent_Instance,
	now_ms, idle_ms: i64,
}

canonical_idle_guard :: proc(raw: rawptr) -> domain.Domain_Error {
	g := (^Canonical_Idle_Guard)(raw)
	inst, err := canonical_lifecycle_state(&g.canonical)
	if err.code != .None do return err
	defer domain.agent_instance_destroy(&inst)
	if !content.message_delivery_assignment_matches(inst,g.expected^) ||
	   !agent.runtime_expected_active(inst.runtime_status) || inst.runtime_status=="stopping" || inst.activity_status!="idle" ||
	   inst.startup_status!="ready" || inst.stopped_by!="" || inst.stop_reason!="" {
		return bots_detail_error(.Conflict,"bot_is_not_idle")
	}
	s := g.canonical.service
	uow, read_ok, read_err := iface.unit_of_work_begin(s.uow_factory)
	if !read_ok do return read_err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	activity, _, stamp_err := iface.agent_get_user_activity(&uow.repos.agents,inst.agent_instance_id)
	if stamp_err.code != .None do return stamp_err
	c, have_chat, chat_err := iface.content_get_conversation(&uow.repos.content,inst.conversation_id)
	if chat_err.code != .None do return chat_err
	if !have_chat || c.owner_user_id!=inst.owner_user_id || c.agent_instance_id!=inst.agent_instance_id do return bots_detail_error(.Not_Found,"bot_conversation_missing")
	last := max(bots_stamp_ms(inst.started_at),bots_stamp_ms(c.last_message_at),bots_stamp_ms(activity))
	if last<=0 || g.now_ms-last<g.idle_ms do return bots_detail_error(.Conflict,"bot_is_not_idle")
	rows, list_err := iface.content_list_agent_inbox_messages(&uow.repos.content,c.conversation_id,c.owner_user_id,inst.agent_instance_id,true,true,false,false,1,"",true,inst.runtime_transport=="acp")
	if list_err.code != .None do return list_err
	if len(rows)>0 do return bots_detail_error(.Conflict,"bot_has_unread_input")
	cutoff := platform.format_rfc3339_utc(time.Time{_nsec=(g.now_ms-g.idle_ms)*1_000_000})
	active, action_err := iface.bot_action_activity(&uow.repos.bots,inst.agent_instance_id,cutoff)
	if action_err.code != .None do return action_err
	if active do return bots_detail_error(.Conflict,"bot_has_open_activity")
	return {}
}

stop_canonical_when_idle :: proc(s: ^Bots_Service, owner: string, ms: i64) {
	if s.agents==nil || s.uow_factory==nil || s.timers.bot_idle_stop_ms<=0 do return
	state, found, err := iface.bot_web_activation_get(s.repo,owner)
	if err.code != .None || !found || !state.enabled do return
	g := Canonical_Lifecycle_Guard{s,owner,state.conversation_id,state.agent_instance_id,state.generation}
	inst, read_err := canonical_lifecycle_state(&g)
	if read_err.code != .None do return
	guard := Canonical_Idle_Guard{g,&inst,ms,s.timers.bot_idle_stop_ms}
	if canonical_idle_guard(&guard).code != .None do return
	if gate := bots_gate_error(s.experiments,owner); gate.code != .None do return
	_, _, _ = agent.stop_instance(s.agents,{kind=.Internal_User,user_id=owner},inst.agent_instance_id,{reason=agent.STOP_IDLE_TTL},&guard,canonical_idle_guard)
}
