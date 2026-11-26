package taskv2

import "core:fmt"
import "core:hash"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

// Agent verbs that land in M1: `lease.next` and `lease.heartbeat`. (submit /
// handoff / block / review.post / task.fetch are M2.) Each is one UoW.

Lease_Next_Input :: struct {
	// vcs_base: the bridge's .Local enrichment (git head at lease start). When
	// present and no attempt_started exists for the current attempt, it is recorded.
	vcs_base: string,
	// peek: when true, returns the caller's existing lease (or status="none")
	// without granting a new ready task inline (a read-only lease check).
	peek:     bool,
	// pack_version: the version of the pack the caller already has (REQ-SCHED-39).
	// When it still matches, the pack is not built and pack_json is omitted.
	pack_version: string,
}

Lease_Next_Result :: struct {
	// status ∈ {granted, current, waiting, none}
	status:    string,
	lease:     domain.Task_Lease,
	task:      domain.Task,
	// pack_json is "" when the caller's pack_version still matches.
	pack_json: string,
	pack_version: string,
	// status none with an item for the caller that could not be granted
	// (REQ-SCHED-41): that task and the first refusal reason.
	refused_task_id: domain.Task_ID,
	reason:          string,
}

// lease_next (plan §2.5): idempotent. An instance holding a lease gets it back
// (and the call confirms a wake-delivered lease); a lease-free instance — the
// coordinator included — is granted inline (never woken) what its agent is
// assigned or owes, unless `input.peek` is set (REQ-SCHED-12).
//
// Cost (spec SCHED section 10, REQ-SCHED-38..40): the held paths read the
// lease, the task and its events once, then the pack version inputs; the pack
// is built only when the version changed. The idle path is two index lookups
// (grant_inline_for_instance). Nothing here reads the chain's other tasks.
lease_next :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Lease_Next_Input) -> (Lease_Next_Result, bool, domain.Domain_Error) {
	inst, ok, err := instance_from_auth(svc, auth)
	if !ok do return {}, false, err
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	res := Lease_Next_Result{status = "none"}
	rok := true
	rerr := domain.Domain_Error{}
	// The held task's events, read once and passed down; nil when stale.
	evs: []domain.Task_Event
	if lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id); held {
		task, tfound, terr := iface.taskchain_get_task(svc.repo, lease.task_id)
		if !tfound { _, _ = end_uow(svc, &u, false); return {}, false, terr }
		if loaded, eerr := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id); eerr.code == .None do evs = loaded
		if !input.peek && transfer_reservation_needs_activation(svc, task, lease, evs) && !ownership_cleanup_pending(svc, task) {
			claimed, accepted, claim_err := lease_claim_in_uow(svc, &u, auth, Lease_Claim_Input{task_id = lease.task_id, vcs_base = input.vcs_base})
			_, commit_err := end_uow(svc, &u, accepted)
			if !accepted do return {}, false, claim_err
			return Lease_Next_Result{status = claimed.status, lease = claimed.lease, task = claimed.task, pack_json = claimed.pack_json, pack_version = pack_version_for(svc, claimed.task, claimed.lease)}, commit_err.code == .None, commit_err
		}
		if lease.phase == domain.LEASE_PHASE_WAITING {
			if !input.peek && ((lease.kind == domain.LEASE_KIND_WORK && task.state == .Ready) || (lease.kind == domain.LEASE_KIND_REVIEW && task.state == .In_Review && task.attempt_no != lease.attempt_no)) {
				if chain, found, _ := iface.taskchain_get_chain(svc.repo, task.chain_id); found {
					if next, fresh, granted, _ := grant_inline_for_instance(svc, &u, chain, inst, .Lease_Next); granted {
						record_attempt_started(svc, fresh, next, input.vcs_base)
						if err := requirements_present(svc, fresh, next); err.code != .None { _, _ = end_uow(svc, &u, false); return {}, false, err }
						pack := build_pack_json(svc, chain, fresh, next, inst)
						version := pack_version_for(svc, fresh, next)
						_, err := end_uow(svc, &u, true)
						return Lease_Next_Result{status = "granted", lease = next, task = fresh, pack_json = pack, pack_version = version}, err.code == .None, err
					}
				}
			}
			// Refresh TASK.md even while waiting; an old active pack must not
			// tell the retained holder to execute or submit again. Unchanged
			// inputs mean the caller's pack is still this one.
			res = Lease_Next_Result{status = "waiting", lease = lease, task = task}
		} else {
			fresh := lease
			if lease.confirmed_at == "" {
				_ = confirm_in_uow(svc, &u, lease)
				fresh, _, _ = iface.taskchain_get_lease(svc.repo, lease.lease_id)
				evs = nil // confirm_in_uow appended lease_confirmed
			}
			if !input.peek {
				appended, perr := requirements_present_events(svc, task, fresh, evs)
				if perr.code != .None {
					_, _ = end_uow(svc, &u, false)
					return {}, false, perr
				}
				if appended do evs = nil
			}
			if record_attempt_started(svc, task, fresh, input.vcs_base, evs) do evs = nil
			res = Lease_Next_Result{status = "current", lease = fresh, task = task}
		}
	} else if recently_expired(svc, inst.agent_instance_id, now_ms(svc.clock)) {
		// The caller's lease just expired: it is being stopped and will be
		// re-woken with a fresh pack. No inline grant for an orphan.
		_, _ = end_uow(svc, &u, false)
		return {}, false, lease_lost_error()
	} else if !input.peek && inst.chain_id != "" {
		if chain, cok, _ := iface.taskchain_get_chain(svc.repo, domain.Task_Chain_ID(inst.chain_id)); cok {
			if lease, task, granted, refusal := grant_inline_for_instance(svc, &u, chain, inst, .Lease_Next); granted {
				record_attempt_started(svc, task, lease, input.vcs_base)
				res = Lease_Next_Result{status = "granted", lease = lease, task = task}
				if perr := requirements_present(svc, task, lease); perr.code != .None {
					_, _ = end_uow(svc, &u, false)
					return {}, false, perr
				}
			} else if refusal.task_id != "" {
				res.refused_task_id = refusal.task_id
				res.reason = refusal.reason
			}
		}
	}
	if rok && res.status != "none" {
		res.pack_version = pack_version_for(svc, res.task, res.lease)
		if res.status == "granted" || res.pack_version == "" || input.pack_version != res.pack_version {
			if chain, cok, _ := iface.taskchain_get_chain(svc.repo, res.task.chain_id); cok {
				res.pack_json = build_pack_json(svc, chain, res.task, res.lease, inst, evs)
			}
		}
	}
	_, cerr := end_uow(svc, &u, rok)
	if !rok do return {}, false, rerr
	if cerr.code != .None do return {}, false, cerr
	return res, true, domain.Domain_Error{}
}

Lease_Heartbeat_Input :: struct {
	acknowledge_requirements_revision: i64,
	lease_id: string,
	note:     string,
}

// lease_heartbeat extends the TTL (never past the hard cap). 409 lease_lost when
// the caller holds nothing or names a lease it does not hold.
lease_heartbeat :: proc(svc: ^Service, auth: contracts.Auth_Context, input: Lease_Heartbeat_Input) -> (domain.Task_Lease, bool, domain.Domain_Error) {
	if input.acknowledge_requirements_revision != 0 && input.lease_id == "" {
		return {}, false, domain.domain_error(.Validation_Failed, "lease_id is required to acknowledge requirements")
	}
	inst, ok, err := instance_from_auth(svc, auth)
	if !ok do return {}, false, err
	u, uok, uerr := begin_uow(svc)
	if !uok do return {}, false, uerr
	lease, held, _ := iface.taskchain_get_lease_by_holder(svc.repo, inst.agent_instance_id)
	if !held || (strings.trim_space(input.lease_id) != "" && input.lease_id != lease.lease_id) {
		_, _ = end_uow(svc, &u, false)
		return {}, false, lease_lost_error()
	}
	if input.acknowledge_requirements_revision != 0 {
		task, found, terr := iface.taskchain_get_task(svc.repo, lease.task_id)
		if !found { _, _ = end_uow(svc, &u, false); return {}, false, terr }
		if aerr := requirements_ack_in_uow(svc, task, lease, input.acknowledge_requirements_revision); aerr.code != .None {
			_, _ = end_uow(svc, &u, false); return {}, false, aerr
		}
		effect_publish_task(&u, task, "requirements_acknowledged")
	}
	saved, hok, herr := heartbeat_in_uow(svc, &u, lease, Actor{kind = ACTOR_AGENT, id = inst.agent_instance_id}, input.note)
	_, cerr := end_uow(svc, &u, hok)
	if !hok do return {}, false, herr
	if cerr.code != .None do return {}, false, cerr
	return saved, true, domain.Domain_Error{}
}

// ---- helpers ---------------------------------------------------------------------------

instance_from_auth :: proc(svc: ^Service, auth: contracts.Auth_Context) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	if auth.kind != .Instance_Token || auth.agent_instance_id == "" do return {}, false, domain.domain_error(.Forbidden, "instance token is required")
	inst, ok, err := iface.agent_get_instance(svc.agents, auth.agent_instance_id)
	if !ok do return {}, false, err
	if string(inst.owner_user_id) != auth.user_id do return {}, false, domain.domain_error(.Not_Found, "agent instance not found")
	return inst, true, domain.Domain_Error{}
}

// record_attempt_started returns true when it appended the event. `known_events`
// are the task's events when the caller already read them.
record_attempt_started :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease, vcs_base: string, known_events: []domain.Task_Event = nil) -> bool {
	if lease.kind != domain.LEASE_KIND_WORK do return false
	evs := known_events
	if evs == nil {
		loaded, err := iface.taskchain_list_events_by_task(svc.repo, task.task_id, task.owner_user_id)
		if err.code != .None do return false
		evs = loaded
	}
	marker := fmt.tprintf(`"attempt_no":%d`, lease.attempt_no)
	for e in evs {
		if e.kind == EV_ATTEMPT_STARTED && strings.contains(e.payload_json, marker) do return false
	}
	p := json_begin()
	json_int(&p, "attempt_no", i64(lease.attempt_no))
	json_str(&p, "lease_id", lease.lease_id)
	json_str(&p, "vcs_base", strings.trim_space(vcs_base))
	_, appended, _ := append_event(svc.repo, svc.clock, task, Actor{kind = ACTOR_AGENT, id = lease.holder_instance_id}, EV_ATTEMPT_STARTED, json_end(&p))
	return appended
}

// pack_version (spec SCHED 10.2, REQ-SCHED-39) identifies the pack `lease next`
// would build for (task, lease). Inputs: the task id; the last event id of the
// task (every requirements change, review, answer, hold, handoff and grant is a
// task event, so the requirements revision moves it too); the lease id and
// phase; the chain summary version; and the task row's updated_at, state and
// attempt (brief/title edits and hold changes save the row). Two point reads.
//
// Without a chain_summaries row the pack carries the mechanical summary, which
// changes with other tasks and has no version: the version is then "" and the
// pack is always built (published chains always have a row). Accepted gaps,
// which do not change what the holder must do: the chain title and directory
// rows (renaming the chain or moving a directory path refreshes TASK.md with
// the next task event); `lease next --refresh` forces a fresh pack.
pack_version_for :: proc(svc: ^Service, task: domain.Task, lease: domain.Task_Lease) -> string {
	summary, found, _ := iface.taskchain_get_chain_summary(svc.repo, task.chain_id, task.owner_user_id)
	if !found do return ""
	last, _ := iface.taskchain_latest_event_id(svc.repo, task.task_id, task.owner_user_id)
	return pack_version_from(task, lease, last, summary.version)
}

pack_version_from :: proc(task: domain.Task, lease: domain.Task_Lease, last_event_id: i64, summary_version: int) -> string {
	raw := fmt.tprintf("%d|%s|%d|%s|%s|%d|%s|%s|%d", PACK_VERSION, task.task_id, last_event_id, lease.lease_id, lease.phase, summary_version, task.updated_at, domain.task_state_string(task.state), task.attempt_no)
	return fmt.tprintf("pv%d-%016x", PACK_VERSION, hash.fnv64a(transmute([]u8)raw))
}
