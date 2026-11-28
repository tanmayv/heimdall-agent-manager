package bots

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent_service "odin_test:hub/service/agent"
import project_service "odin_test:hub/service/project"

Bot_Notice :: struct {owner, bot_id, through_message_id, text: string}

// Caller holds mutex. Notices are queued in tick scratch, sent after unlocking.
bots_wait_locked :: proc(s: ^Bots_Service, d: domain.Bot_Delivery, reason, now: string) {
	updated := d
	updated.state, updated.waiting_reason, updated.updated_at = .Waiting, reason, now
	_, _ = iface.delivery_update(s.repo, updated, d.state)
}

bots_abandon_locked :: proc(s: ^Bots_Service, d: domain.Bot_Delivery, reason, now: string) -> bool {
	context.allocator = context.temp_allocator
	uow, ok, err := iface.unit_of_work_begin(s.uow_factory)
	if !ok || err.code != .None do return false
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	attempts, e := iface.attempt_list_for_delivery(s.repo, d.delivery_id)
	if e.code != .None do return false
	for a in attempts {
		if domain.bot_attempt_state_open(a.state) {
			updated := a
			updated.state, updated.finished_at = .Cancelled, now
			if _, e := iface.attempt_update(s.repo, updated, a.state); e.code != .None do return false
		}
	}
	updated := d
	updated.state, updated.finish_reason, updated.finished_at, updated.updated_at = .Abandoned, reason, now, now
	changed, update_err := iface.delivery_update(s.repo, updated, d.state)
	if !changed || update_err.code != .None do return false
	committed, _ := bots_uow_commit(&uow)
	if committed && reason == "all_tried" do bots_queue_gave_up_locked(s, d.owner_user_id, d.bot_id, d.through_message_id)
	return committed
}

bots_wake_locked :: proc(s: ^Bots_Service, d: domain.Bot_Delivery, now: string) -> bool {
	context.allocator = context.temp_allocator
	attempts, err := iface.attempt_list_for_delivery(s.repo, d.delivery_id)
	if err.code != .None do return false
	updated := d
	updated.waiting_reason = ""
	for a in attempts {
		if a.round == d.round {updated.round += 1; break}
	}
	if updated.round > s.timers.bot_max_rounds {
		// Leave the attempt count/round snapshot intact while applying terminal CAS.
		updated.state, updated.finish_reason, updated.finished_at, updated.updated_at = .Abandoned, "max_rounds", now, now
		changed, e := iface.delivery_update(s.repo, updated, .Waiting)
		if changed && e.code == .None {bots_queue_gave_up_locked(s, d.owner_user_id, d.bot_id, d.through_message_id); return true}
		return false
	}
	updated.state, updated.waiting_reason, updated.updated_at = .Pending, "", now
	_, _ = iface.delivery_update(s.repo, updated, .Waiting)
	return false
}

bots_has_eligible :: proc(s: ^Bots_Service, bot: domain.Bot, d: domain.Bot_Delivery) -> bool {
	context.allocator = context.temp_allocator
	// A synthetic round with no attempts computes E, using the same full eligibility
	// predicate/ranking as selection. Durable rounds start at one.
	id, found := bots_select_bridge(s, bot, d, 0)
	return found && id != ""
}

// Release s.mutex around agent service calls. Activation serializes old lifecycle
// admission through web_activation_mutex, which always precedes s.mutex.
bots_dispatch_locked :: proc(s: ^Bots_Service, bot: domain.Bot, d: domain.Bot_Delivery, bridge_id, now: string) {
	context.allocator = context.temp_allocator
	if bots_legacy_guard(s, bot.owner_user_id).code != .None do return
	policy, err := iface.placement_list(s.repo, bot.bot_id)
	if err.code != .None do return
	candidates := bots_expand_candidates(s, bot, policy, bridge_id)
	if len(candidates) == 0 do return
	candidate_json, marshal_err := json.marshal(candidates)
	if marshal_err != nil do return
	a := domain.Bot_Delivery_Attempt{
		attempt_id = platform.generate_id(s.ids, "bda_"), delivery_id = d.delivery_id, round = d.round,
		bridge_id = bridge_id, state = .Relocating, candidates_json = string(candidate_json), created_at = now,
	}
	// Reserve the one open attempt and delivery atomically before dropping mutex.
	uow, ok, begin_err := iface.unit_of_work_begin(s.uow_factory)
	if !ok || begin_err.code != .None do return
	defer if uow.ctx != nil do iface.unit_of_work_rollback(&uow)
	updated := d
	updated.state, updated.updated_at = .Dispatched, now
	changed, e := iface.delivery_update(s.repo, updated, .Pending)
	if !changed || e.code != .None do return
	if e := iface.attempt_insert(s.repo, a); e.code != .None do return
	if committed, _ := bots_uow_commit(&uow); !committed do return
	candidate := candidates[0]
	instance_id := bot.agent_instance_id
	if instance_id == "" {
		sync.mutex_unlock(&s.mutex)
		sync.mutex_lock(&s.web_activation_mutex)
		if bots_legacy_guard(s, bot.owner_user_id).code != .None {
			sync.mutex_unlock(&s.web_activation_mutex)
			sync.mutex_lock(&s.mutex)
			return
		}
		inst, prepared, prepare_err := agent_service.create_instance_stopped(s.agents, {kind = .Internal_User, user_id = bot.owner_user_id},
			{fleet_scope = "excluded", agent_id = bot.agent_id, bridge_id = bridge_id, provider = candidate.provider, provider_profile = candidate.provider_profile, model = candidate.model, display_name = bot.display_name})
		sync.mutex_lock(&s.mutex)
		sync.mutex_unlock(&s.web_activation_mutex)
		if !prepared {
			a.report_json = bots_reason_json("prepare_refused", prepare_err.message)
			_ = bots_finish_attempt_locked(s, a, .Exhausted, now)
			return
		}
		instance_id = inst.agent_instance_id
		if e := iface.bot_set_instance(s.repo, bot.bot_id, instance_id, now); e.code != .None {
			_ = bots_finish_attempt_locked(s, a, .Exhausted, now)
			return
		}
	}
	current, open, current_err := iface.attempt_get(s.repo, a.attempt_id)
	if !open || current_err.code != .None || current.state != .Relocating do return
	inst, exists, inst_err := iface.agent_get_instance(s.agents.agents, instance_id)
	if !exists || inst_err.code != .None {_ = bots_finish_attempt_locked(s, current, .Exhausted, now); return}
	if inst.bridge_id == bridge_id {bots_send_attempt_locked(s, current); return}
	key := fmt.tprintf("bot:%s", a.attempt_id)
	current.relocation_key = key
	if changed, e := iface.attempt_update(s.repo, current, .Relocating); !changed || e.code != .None do return
	sync.mutex_unlock(&s.mutex)
	sync.mutex_lock(&s.web_activation_mutex)
	if bots_legacy_guard(s, bot.owner_user_id).code != .None {
		sync.mutex_unlock(&s.web_activation_mutex)
		sync.mutex_lock(&s.mutex)
		return
	}
	_, relocated, relocate_err := agent_service.begin_instance_reconfiguration(s.agents, {kind = .Internal_User, user_id = bot.owner_user_id}, instance_id,
		{bridge_id = bridge_id, project_id = "", provider = candidate.provider, provider_profile = candidate.provider_profile,
		model = candidate.model, idempotency_key = key, expected_revision = inst.configuration_revision})
	sync.mutex_unlock(&s.web_activation_mutex)
	sync.mutex_lock(&s.mutex)
	if bots_legacy_guard(s, bot.owner_user_id).code != .None do return
	current, open, current_err = iface.attempt_get(s.repo, a.attempt_id)
	if !open || current_err.code != .None || current.state != .Relocating do return
	if !relocated {
		if relocate_err.code == .Conflict && bots_resolve_blocking_locked(s, current, bot, now) do return
		current.report_json = bots_reason_json("relocation_refused", relocate_err.message)
		_ = bots_finish_attempt_locked(s, current, .Exhausted, now)
	}
}

bots_reason_json :: proc(reason, detail: string) -> string {
	data, _ := json.marshal(struct {reason, detail: string}{reason, detail})
	return string(data)
}

bots_resolve_blocking_locked :: proc(s: ^Bots_Service, a: domain.Bot_Delivery_Attempt, bot: domain.Bot, now: string) -> bool {
	context.allocator = context.temp_allocator
	ops, err := iface.instance_reconfiguration_list(s.agents.agents, bot.owner_user_id, bot.agent_instance_id, true)
	if err.code != .None do return false
	for op in ops {
		if !domain.instance_reconfiguration_blocks_input(op) do continue
		// Track the blocking operation, even if a previous dispatch created it.
		updated := a
		updated.relocation_key = op.idempotency_key
		_, _ = iface.attempt_update(s.repo, updated, a.state)
		inst, found, e := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
		if !found || e.code != .None do return true
		if !project_service.bridge_runtime_registry_has_live(s.registry, inst.bridge_id) {
			_ = bots_finish_attempt_locked(s, updated, .Disconnected, now, true)
			return true
		}
		// Do not repeatedly force stop while the stop acknowledgement is pending.
		if inst.runtime_status != "stopping" {
			sync.mutex_unlock(&s.mutex)
			_, _, _ = agent_service.stop_instance(s.agents, {kind = .Internal_User, user_id = bot.owner_user_id}, inst.agent_instance_id, {reason = "bot_recovery", force = true})
			sync.mutex_lock(&s.mutex)
		}
		return true
	}
	return false
}

bots_attempt_tick_locked :: proc(s: ^Bots_Service, a: domain.Bot_Delivery_Attempt, now: string, ms: i64) {
	context.allocator = context.temp_allocator
	if bots_legacy_attempt_guard(s, a).code != .None do return
	if ms - bots_stamp_ms(a.created_at) > s.timers.bot_attempt_total_ms {
		_ = bots_finish_attempt_locked(s, a, .Deadline, now); return
	}
	if a.disconnected_at != "" && ms - bots_stamp_ms(a.disconnected_at) > s.timers.bot_disconnect_grace_ms {
		_ = bots_finish_attempt_locked(s, a, .Disconnected, now); return
	}
	if a.state == .Relocating {
		if ms - bots_stamp_ms(a.created_at) >= s.timers.bot_relocation_wait_ms {
			_ = bots_finish_attempt_locked(s, a, .Deadline, now); return
		}
		d, _, _ := iface.delivery_get(s.repo, a.delivery_id)
		bot, _, _ := iface.bot_get(s.repo, d.bot_id)
		if bot.agent_instance_id == "" do return
		op, found, err := iface.instance_reconfiguration_get(s.agents.agents, bot.owner_user_id, bot.agent_instance_id, a.relocation_key)
		if err.code != .None || !found do return
		if op.phase == .Ready {bots_send_attempt_locked(s, a); return}
		if op.phase == .Failed {
			candidates: []contracts.Bot_Candidate_Wire
			if json.unmarshal(transmute([]u8)(a.candidates_json), &candidates) == nil && len(candidates) > 0 {
				c := candidates[0]
				bots_send_attempt_locked(s, a, false, {{provider = c.provider, model = c.model, reason = "relocation_failed"}})
			}
		} else if op.phase == .Recovery_Required {
			_ = bots_resolve_blocking_locked(s, a, bot, now)
		}
		return
	}
	if a.state == .Sent && ms - bots_stamp_ms(a.sent_at) >= s.timers.bot_attempt_accept_ms {
		_ = bots_finish_attempt_locked(s, a, .Deadline, now)
	} else if a.state == .Accepted && ms - max(bots_stamp_ms(a.last_report_at), bots_stamp_ms(a.accepted_at), s.boot_unix_ms) > s.timers.bot_attempt_silence_ms {
		_ = bots_finish_attempt_locked(s, a, .Deadline, now)
	}
}

// One deterministic tick; runtime.odin owns the interruptible thread and arena.
bots_supervisor_tick :: proc(s: ^Bots_Service) {
	if s == nil do return
	context.allocator = context.temp_allocator
	sync.mutex_lock(&s.mutex)
	now := platform.clock_now(s.clock)
	ms := bots_stamp_ms(now)
	attempts, attempt_err := iface.attempt_list_open(s.repo)
	if attempt_err.code == .None {
		for a in attempts do bots_attempt_tick_locked(s, a, now, ms)
	}
	deliveries, delivery_err := iface.delivery_list_open(s.repo)
	if delivery_err.code == .None {
		for d in deliveries {
			if d.state != .Pending || (!bots_gate_on(s.experiments, d.owner_user_id) || bots_legacy_guard(s, d.owner_user_id).code != .None) do continue
			bot, found, err := iface.bot_get(s.repo, d.bot_id)
			if !found || err.code != .None do continue
			bridge_id, selected := bots_select_bridge(s, bot, d, d.round)
			if selected {bots_dispatch_locked(s, bot, d, bridge_id, now); continue}
			if !bots_has_eligible(s, bot, d) {bots_wait_locked(s, d, "no_bridge", now); continue}
			all, e := iface.attempt_list_for_delivery(s.repo, d.delivery_id)
			if e.code != .None do continue
			busy, any_attempt, terminal := false, false, true
			for a in all {
				if a.round != d.round do continue
				any_attempt = true
				if domain.bot_attempt_state_open(a.state) do terminal = false
				if a.state == .Busy do busy = true
			}
			if any_attempt && terminal {
				if busy {bots_wait_locked(s, d, "busy", now)} else {_ = bots_abandon_locked(s, d, "all_tried", now)}
			}
		}
	}
	hellos := s.hello_queue
	s.hello_queue = nil
	defer {
		for id in hellos do delete(id, runtime.heap_allocator())
		delete(hellos)
	}
	periodic := ms - s.last_waiting_recheck_ms >= s.timers.bot_waiting_recheck_ms
	deliveries, delivery_err = iface.delivery_list_open(s.repo)
	if delivery_err.code == .None {
		for d in deliveries {
			if d.state != .Waiting || (!bots_gate_on(s.experiments, d.owner_user_id) || bots_legacy_guard(s, d.owner_user_id).code != .None) do continue
			bot, found, err := iface.bot_get(s.repo, d.bot_id)
			if !found || err.code != .None do continue
			wake := false
			if d.waiting_reason == "busy" {
				all, e := iface.attempt_list_for_delivery(s.repo, d.delivery_id)
				newest := ""
				if e.code == .None do for a in all do if a.round == d.round && a.state == .Busy && a.finished_at > newest do newest = a.finished_at
				wake = newest != "" && ms - bots_stamp_ms(newest) >= s.timers.bot_busy_retry_ms
			} else if d.waiting_reason == "no_bridge" {
				recheck := periodic
				for id in hellos {
					b, ok, e := iface.bridge_get_bridge(s.bridges, id)
					if ok && e.code == .None && string(b.owner_user_id) == d.owner_user_id do recheck = true
				}
				wake = recheck && bots_has_eligible(s, bot, d)
			} else if d.waiting_reason == "relocation_stranded" && bot.agent_instance_id != "" {
				inst, ok, e := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
				if ok && e.code == .None do for id in hellos do if id == inst.bridge_id do wake = true
			}
			if wake do _ = bots_wake_locked(s, d, now)
		}
	}
	if periodic do s.last_waiting_recheck_ms = ms
	// Collect exactly-once waiting/give-up notices in the supervisor. Hooks and
	// placement never perform Telegram I/O. Terminal notices are queued at CAS.
	notices := make([dynamic]Bot_Notice)
	for notice in s.notices do append(&notices, Bot_Notice{strings.clone(notice.owner), strings.clone(notice.bot_id), strings.clone(notice.through_message_id), strings.clone(notice.text)})
	for notice in s.notices {delete(notice.owner, runtime.heap_allocator()); delete(notice.bot_id, runtime.heap_allocator()); delete(notice.through_message_id, runtime.heap_allocator()); delete(notice.text, runtime.heap_allocator())}
	clear(&s.notices)
	waiting, _ := iface.delivery_list_open(s.repo)
	for d in waiting {
		if d.state != .Waiting || d.waiting_notice_at != "" || d.waiting_reason == "busy" || bots_legacy_guard(s, d.owner_user_id).code != .None do continue
		updated := d
		updated.waiting_notice_at, updated.updated_at = now, now
		if changed, e := iface.delivery_update(s.repo, updated, .Waiting); changed && e.code == .None {
			append(&notices, Bot_Notice{d.owner_user_id, d.bot_id, d.through_message_id, COPY_NO_MACHINE})
		}
	}
	run_idle := ms - s.last_idle_check_ms >= 60_000
	if run_idle do s.last_idle_check_ms = ms
	run_retention := ms - s.last_retention_ms >= 3_600_000
	if run_retention do s.last_retention_ms = ms
	sync.mutex_unlock(&s.mutex)
	for notice in notices {
		if !bots_gate_on(s.experiments, notice.owner) do continue
		binding, found, _ := bots_notice_binding(s, notice.owner, notice.bot_id, notice.through_message_id)
		if found do bots_notice(s, binding.provider, binding.external_chat_id, notice.text, notice.owner)
	}
	bots_canonical_egress_tick(s,domain.CHANNEL_PROVIDER_TELEGRAM,ms)
	bots_canonical_feedback_tick(s,domain.CHANNEL_PROVIDER_TELEGRAM)
	if run_idle {
		bots_idle_stop(s, now, ms)
		bots_whatsapp_entitlement_sweep(s)
	}
	if run_retention {
		cutoff := platform.format_rfc3339_utc(time.Time{_nsec = (ms - s.timers.bot_channel_retention_ms) * 1_000_000})
		_, _ = iface.messages_purge_older_than(s.repo, cutoff)
		processed_cutoff := platform.format_rfc3339_utc(time.Time{_nsec = (ms - 7*24*60*60*1000) * 1_000_000})
		_, _ = iface.push_events_purge_processed(s.repo, processed_cutoff)
	}
}

bots_queue_gave_up_locked :: proc(s: ^Bots_Service, owner, bot_id, through_message_id: string) {
	if s.notices.allocator.procedure == nil do s.notices = make([dynamic]Bot_Notice, runtime.heap_allocator())
	append(&s.notices, Bot_Notice{strings.clone(owner, runtime.heap_allocator()), strings.clone(bot_id, runtime.heap_allocator()), strings.clone(through_message_id, runtime.heap_allocator()), strings.clone(COPY_GAVE_UP, runtime.heap_allocator())})
}

bots_idle_stop :: proc(s: ^Bots_Service, now: string, ms: i64) {
	context.allocator = context.temp_allocator
	bots, err := iface.bot_list(s.repo)
	if err.code != .None || s.agents == nil do return
	for bot in bots {
		stop_canonical_when_idle(s,bot.owner_user_id,ms)
		if bot.agent_instance_id == "" || (!bots_gate_on(s.experiments, bot.owner_user_id) || bots_legacy_guard(s, bot.owner_user_id).code != .None) do continue
		sync.mutex_lock(&s.mutex)
		_, open, e := iface.delivery_get_open(s.repo, bot.bot_id)
		recent, recent_err := iface.delivery_list_recent(s.repo, bot.bot_id, 1)
		stamp := bot.updated_at
		if len(recent) > 0 do stamp = recent[0].finished_at
		inst, found, inst_err := iface.agent_get_instance(s.agents.agents, bot.agent_instance_id)
		stop := !open && e.code == .None && recent_err.code == .None && found && inst_err.code == .None &&
			agent_service.runtime_expected_active(inst.runtime_status) && stamp != "" && ms - bots_stamp_ms(stamp) > s.timers.bot_idle_stop_ms
		sync.mutex_unlock(&s.mutex)
		if stop {
			cutoff := platform.format_rfc3339_utc(time.Time{_nsec = (ms - s.timers.bot_idle_stop_ms) * 1_000_000})
			active, activity_err := iface.bot_action_activity(s.repo, bot.agent_instance_id, cutoff)
			stop = !active && activity_err.code == .None
		}
		if stop do _, _, _ = agent_service.stop_instance(s.agents, {kind = .Internal_User, user_id = bot.owner_user_id}, inst.agent_instance_id, {reason = "bot_idle"})
	}
}

// Called after bots_runtime_stop joins both workers, before DB teardown.
bots_service_destroy :: proc(s: ^Bots_Service) {
	for id in s.hello_queue do delete(id, runtime.heap_allocator())
	delete(s.hello_queue)
	s.hello_queue = nil
	for notice in s.notices {delete(notice.owner, runtime.heap_allocator()); delete(notice.bot_id, runtime.heap_allocator()); delete(notice.through_message_id, runtime.heap_allocator()); delete(notice.text, runtime.heap_allocator())}
	delete(s.notices)
	s.notices = nil
}
