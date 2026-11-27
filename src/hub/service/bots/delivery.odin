package bots

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

// All snapshots and wire objects in a delivery operation use caller scratch.
// The runtime resets its arena every tick; HTTP/WS callers own request scratch.
bots_now_ms :: proc(s: ^Bots_Service) -> i64 {
	ms, _ := platform.rfc3339_to_unix_ms(platform.clock_now(s.clock))
	return ms
}
bots_stamp_ms :: proc(stamp: string) -> i64 {ms, _ := platform.rfc3339_to_unix_ms(stamp); return ms}

// Caller holds mutex. R3 is part of the same transaction as the terminal change.
bots_finish_attempt_locked :: proc(s: ^Bots_Service, a: domain.Bot_Delivery_Attempt, state: domain.Bot_Attempt_State, now: string, stranded := false) -> domain.Domain_Error {
	context.allocator = context.temp_allocator
	uow, ok, err := iface.unit_of_work_begin(s.uow_factory)
	if !ok do return err
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	next := a
	next.state, next.finished_at = state, now
	changed, update_err := iface.attempt_update(s.repo, next, a.state)
	if update_err.code != .None do return update_err
	if !changed do return {}
	d, found, get_err := iface.delivery_get(s.repo, a.delivery_id)
	if get_err.code != .None do return get_err
	if found && d.state == .Dispatched {
		updated := d
		updated.updated_at = now
		if state == .Acted {
			updated.state, updated.finish_reason, updated.finished_at = .Acted, "acted", now
		} else if stranded {
			updated.state, updated.waiting_reason = .Waiting, "relocation_stranded"
		} else {
			updated.state = .Pending
		}
		moved, e := iface.delivery_update(s.repo, updated, d.state)
		if e.code != .None do return e
		if moved && state == .Acted {
			if e := bots_delivery_on_inbound_locked(s, d.bot_id, bots_stamp_ms(now)); e.code != .None do return e
		}
	}
	_, commit_err := bots_uow_commit(&uow)
	return commit_err
}

bots_on_command_result :: proc(s: ^Bots_Service, bridge_id, command_id, status, error_code: string) {
	if s == nil || !strings.has_prefix(command_id, "cmd_bot_") do return
	context.allocator = context.temp_allocator
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	a, found, err := iface.attempt_get(s.repo, command_id[len("cmd_bot_"):])
	if !found || err.code != .None || a.bridge_id != bridge_id || a.state != .Sent do return
	now := platform.clock_now(s.clock)
	if status == "accepted" || status == "succeeded" {
		updated := a
		updated.state, updated.accepted_at = .Accepted, now
		_, _ = iface.attempt_update(s.repo, updated, .Sent)
	} else if status == "failed" {
		data, _ := json.marshal(struct {reason: string}{error_code})
		a.report_json = string(data)
		_ = bots_finish_attempt_locked(s, a, .Exhausted, now)
	}
}

bots_on_report :: proc(s: ^Bots_Service, bridge_id, frame_json: string) -> (reply_json: string, parse_failed: bool) {
	// Ack is allocated in the original caller allocator. Parsed data stays scratch.
	caller_allocator := context.allocator
	report: contracts.Bot_Delivery_Report_Wire
	if json.unmarshal(transmute([]u8)(frame_json), &report, allocator = context.temp_allocator) != nil ||
	report.attempt_id == "" || report.seq < 1 ||
	(report.state != "working" && report.state != "acted" && report.state != "exhausted" && report.state != "busy") {return "", true}
	ack, err := json.marshal(contracts.Bot_Delivery_Report_Ack_Wire{type = "bot_delivery_report_ack", attempt_id = report.attempt_id, seq = report.seq})
	if err != nil do return "", true
	if s == nil do return string(ack), false
	context.allocator = context.temp_allocator
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	a, found, get_err := iface.attempt_get(s.repo, report.attempt_id)
	if get_err.code != .None {delete(ack, caller_allocator); return "", false}
	if !found || a.bridge_id != bridge_id || !domain.bot_attempt_state_open(a.state) || a.state == .Relocating || report.seq <= a.report_seq do return string(ack), false
	uow, ok, begin_err := iface.unit_of_work_begin(s.uow_factory)
	if !ok || begin_err.code != .None {delete(ack, caller_allocator); return "", false}
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	updated := a
	updated.report_json, updated.report_seq, updated.last_report_at = frame_json, report.seq, platform.clock_now(s.clock)
	// Persist seq/progress before terminal CAS, under the same service mutex.
	changed, update_err := iface.attempt_update(s.repo, updated, a.state)
	if changed && update_err.code == .None && report.state != "working" {
		state := domain.Bot_Attempt_State.Exhausted
		if report.state == "acted" do state = .Acted
		if report.state == "busy" do state = .Busy
		if e := bots_finish_attempt_locked(s, updated, state, updated.last_report_at); e.code != .None {delete(ack, caller_allocator); return "", false}
	}
	if !changed || update_err.code != .None {delete(ack, caller_allocator); return "", false}
	if committed, _ := bots_uow_commit(&uow); !committed {delete(ack, caller_allocator); return "", false}
	return string(ack), false
}

// Caller holds mutex. Frame always reads current provider/model afresh, even on resend.
bots_send_attempt_locked :: proc(s: ^Bots_Service, a: domain.Bot_Delivery_Attempt, resend := false, skip: []contracts.Bot_Skip_Wire = nil) {
	skip := skip
	d, found, err := iface.delivery_get(s.repo, a.delivery_id)
	if !found || err.code != .None || d.state != .Dispatched do return
	bot, found_bot, bot_err := iface.bot_get(s.repo, d.bot_id)
	if !found_bot || bot_err.code != .None || !bots_gate_on(s.experiments, bot.owner_user_id) do return
	inst, found_inst, inst_err := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
	if !found_inst || inst_err.code != .None do return
	candidates: []contracts.Bot_Candidate_Wire
	if json.unmarshal(transmute([]u8)(a.candidates_json), &candidates) != nil || len(candidates) == 0 do return
	if resend && len(skip) == 0 && a.report_json != "" {
		saved: struct {skip: []contracts.Bot_Skip_Wire}
		if json.unmarshal(transmute([]u8)(a.report_json), &saved) == nil do skip = saved.skip
	}
	if resend && len(skip) == 0 && a.relocation_key != "" {
		op, exists, e := iface.instance_reconfiguration_get(s.agents.agents, bot.owner_user_id, bot.agent_instance_id, a.relocation_key)
		if exists && e.code == .None && op.phase == .Failed {
			c := candidates[0]
			skip = []contracts.Bot_Skip_Wire{{provider = c.provider, model = c.model, reason = "relocation_failed"}}
		}
	}
	messages, msg_err := iface.messages_pending(s.repo, bot.bot_id, -1)
	if msg_err.code != .None do return
	count := 0
	for m in messages do if !m.body_purged do count += 1
	timers := s.timers
	frame := contracts.Bot_Deliver_Wire{
		type = "bot_deliver", command_id = fmt.tprintf("cmd_bot_%s", a.attempt_id),
		bridge_id = a.bridge_id, agent_instance_id = bot.agent_instance_id, bot_id = bot.bot_id,
		delivery_id = d.delivery_id, attempt_id = a.attempt_id, through_message_id = d.through_message_id,
		pending_count = count, current_provider = inst.provider, current_model = inst.model,
		candidates = candidates, skip = skip,
		timers = {launch_ready_ms = timers.launch_ready_ms, read_ms = timers.read_ms,
			read_extend_ms = timers.read_extend_ms, read_max_extends = timers.read_max_extends,
			idle_no_reply_ms = timers.idle_no_reply_ms, reply_cap_ms = timers.reply_cap_ms,
			progress_interval_ms = timers.progress_interval_ms},
	}
	data, marshal_err := json.marshal(frame)
	if marshal_err != nil || s.command_sink == nil do return
	updated := a
	if !resend {
		updated.state, updated.sent_at = .Sent, platform.clock_now(s.clock)
		if len(skip) > 0 {
			saved, _ := json.marshal(struct {skip: []contracts.Bot_Skip_Wire}{skip})
			updated.report_json = string(saved)
		}
		changed, e := iface.attempt_update(s.repo, updated, a.state)
		if !changed || e.code != .None do return
	}
	sent, send_err := project_service.bridge_command_send_runtime(s.command_sink^, {bridge_id = a.bridge_id, command_id = frame.command_id, body_json = string(data)})
	if !resend && !sent && send_err.code == .Bridge_Offline {
		_ = bots_finish_attempt_locked(s, updated, .Disconnected, platform.clock_now(s.clock))
	}
}

bots_on_bridge_hello :: proc(s: ^Bots_Service, bridge_id: string) {
	if s == nil do return
	n, err := iface.experiment_count_enabled(s.experiments, "bots")
	if err.code != .None || n == 0 do return
	context.allocator = context.temp_allocator
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	now_ms := bots_now_ms(s)
	attempts, e := iface.attempt_list_open_on_bridge(s.repo, bridge_id)
	if e.code == .None {
		for a in attempts {
			if a.disconnected_at != "" && now_ms - bots_stamp_ms(a.disconnected_at) > s.timers.bot_disconnect_grace_ms do continue
			updated := a
			updated.disconnected_at = ""
			if changed, e := iface.attempt_update(s.repo, updated, a.state); changed && e.code == .None {
				if a.state == .Sent || a.state == .Accepted do bots_send_attempt_locked(s, updated, true)
			}
		}
	}
	// Queue outlives WS scratch; each string and backing array use heap explicitly.
	if s.hello_queue.allocator.procedure == nil do s.hello_queue = make([dynamic]string, runtime.heap_allocator())
	append(&s.hello_queue, strings.clone(bridge_id, runtime.heap_allocator()))
}

bots_on_bridge_disconnect :: proc(s: ^Bots_Service, bridge_id: string) {
	if s == nil do return
	n, err := iface.experiment_count_enabled(s.experiments, "bots")
	if err.code != .None || n == 0 do return
	context.allocator = context.temp_allocator
	sync.mutex_lock(&s.mutex); defer sync.mutex_unlock(&s.mutex)
	// Transport releases connection state before entering this mutex. A newer
	// hello may already have persisted Online and cleared its grace stamps.
	bridge, found, bridge_err := iface.bridge_get_bridge(s.bridges, bridge_id)
	if bridge_err.code != .None || !found || bridge.status == .Online do return
	attempts, e := iface.attempt_list_open_on_bridge(s.repo, bridge_id)
	if e.code != .None do return
	for a in attempts {
		if a.disconnected_at != "" do continue
		updated := a
		updated.disconnected_at = platform.clock_now(s.clock)
		_, _ = iface.attempt_update(s.repo, updated, a.state)
	}
}

Bot_Switch_View :: struct {
	agent_instance_id, provider, provider_profile, model: string,
	configuration_revision: int,
	relaunched: bool,
}

bots_switch :: proc(s: ^Bots_Service, bridge_id, attempt_id: string, candidate: contracts.Bot_Candidate_Wire) -> (Bot_Switch_View, domain.Domain_Error) {
	context.allocator = context.temp_allocator
	sync.mutex_lock(&s.mutex)
	a, found, err := iface.attempt_get(s.repo, attempt_id)
	if !found || err.code != .None || a.bridge_id != bridge_id || !domain.bot_attempt_state_open(a.state) {
		sync.mutex_unlock(&s.mutex)
		return {}, bots_detail_error(.Not_Found, "bot_attempt_not_found")
	}
	candidates: []contracts.Bot_Candidate_Wire
	allowed := false
	if json.unmarshal(transmute([]u8)(a.candidates_json), &candidates) == nil {
		for c in candidates do if c.provider == candidate.provider && c.model == candidate.model do allowed = true
	}
	if !allowed {sync.mutex_unlock(&s.mutex); return {}, bots_detail_error(.Conflict, "bot_candidate_not_allowed")}
	d, _, _ := iface.delivery_get(s.repo, a.delivery_id)
	bot, _, _ := iface.bot_get(s.repo, d.bot_id)
	inst, exists, inst_err := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
	sync.mutex_unlock(&s.mutex)
	if inst_err.code != .None do return {}, inst_err
	if !exists || inst.bridge_id != bridge_id do return {}, bots_detail_error(.Conflict, "bot_instance_elsewhere")
	if inst.provider == candidate.provider && inst.model == candidate.model {
		return {inst.agent_instance_id, inst.provider, inst.provider_profile, inst.model, inst.configuration_revision, false}, {}
	}
	relaunched: bool
	updated, ok, e := agent_service.reconfigure_instance(s.agents, {kind = .Internal_User, user_id = bot.owner_user_id}, inst.agent_instance_id,
		{provider = candidate.provider, provider_profile = candidate.provider_profile, model = candidate.model}, relaunched = &relaunched)
	if !ok {
		if e.code == .Conflict {
			ops, list_err := iface.instance_reconfiguration_list(s.agents.agents, bot.owner_user_id, inst.agent_instance_id, true)
			if list_err.code == .None {
				for op in ops do if domain.instance_reconfiguration_blocks_input(op) do return {}, bots_detail_error(.Conflict, "bot_relocation_open")
			}
		}
		return {}, e
	}
	return {updated.agent_instance_id, updated.provider, updated.provider_profile, updated.model, updated.configuration_revision, relaunched}, {}
}
