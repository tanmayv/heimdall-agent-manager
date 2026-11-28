package taskv2

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"
import agent "odin_test:hub/service/agent"
import project "odin_test:hub/service/project"
import jsonx "odin_test:lib/jsonx"

@(test)
test_submit_dispatches_legacy_idle_stopped_reviewer :: proc(t: ^testing.T) {
	legacy_idle_stopped_reviewer(t, absence_verified = true)
}

@(test)
test_submit_keeps_review_queued_when_bridge_cannot_verify_absence :: proc(t: ^testing.T) {
	legacy_idle_stopped_reviewer(t, absence_verified = false)
}

// A reviewer stopped before the liveness rollout has a prior generation,
// but neither a Hub stop receipt nor a Bridge identity for the old child.
@(private = "file")
legacy_idle_stopped_reviewer :: proc(t: ^testing.T, absence_verified: bool) {
	fx, log, ok := lease_fixture(t, "legacy_stopped_reviewer")
	defer lease_fixture_close(fx, log)
	if !ok do return
	defer {
		heap := runtime.heap_allocator()
		for id, job in fx.svc.pending_match_probes {
			delete(id, heap)
			delete(string(job.chain_id), heap)
		}
		delete(fx.svc.pending_match_probes)
	}
	chain := seed_live_chain(t, fx, "chain_legacy_stop")
	seed_fleet(fx, chain, "agt_w")
	seed_fleet(fx, chain, "agt_r", capacity = 1)
	seed_instance(fx, chain, "inst_w1", "agt_w", "br_1", "idle")
	reviewer := seed_instance(fx, chain, "inst_r1", "agt_r", "br_1", "stopped")
	reviewer.run_count = 4
	reviewer.launch_epoch = "legacy-review-epoch"
	reviewer.stopped_at = platform.clock_now(&fx.clock)
	_, saved, err := iface.agent_save_instance(&fx.agents, reviewer)
	if !testing.expect(t, saved, err.message) do return
	stopped, stop_err := iface.agent_set_stop_reason(&fx.agents, reviewer.agent_instance_id, string(STOP_REASON_IDLE_TTL))
	if !testing.expect(t, stopped, stop_err.message) do return

	Probe_Fixture :: struct {calls: int, absence_verified: bool}
	probe := Probe_Fixture{absence_verified = absence_verified}
	log.service.bridge_command_sink.ctx = &probe
	log.service.bridge_command_sink.send_runtime_command_wait = proc(ctx: rawptr, cmd: project.Runtime_Command, _: int) -> (string, bool, domain.Domain_Error) {
		probe := (^Probe_Fixture)(ctx)
		if jsonx.extract_string(cmd.body_json, "agent_instance_id", "", true, context.temp_allocator) != "inst_r1" {
			return "", false, domain.domain_error(.Bridge_Offline, "unexpected probe target")
		}
		probe.calls += 1
		// The owning Bridge has a complete empty roster and a clean launch-only
		// scan. Without a launch request the stricter exit probe is unknown.
		reply: struct {
			ok: bool,
			command_id: string,
			payload: struct {
				result: struct {
					agent_instance_id, state, source, launch_epoch: string,
					run_count: int,
				},
			},
		}
		reply.ok, reply.command_id = true, cmd.command_id
		reply.payload.result = {agent_instance_id = "inst_r1", state = "unknown"}
		if probe.absence_verified && jsonx.extract_bool(cmd.body_json, "for_launch", false, true) {
			reply.payload.result = {"inst_r1", "absent", "launch_absence", "legacy-review-epoch", 4}
		}
		wire, wire_err := json.marshal(reply)
		if wire_err != nil do return "", false, domain.domain_error(.Internal_Error, "cannot encode fixture probe")
		return string(wire), true, {}
	}

	_ = publish_task(t, fx, chain, "task_1", brief = `{"goal":"g","assignee":"agt_w","reviewers":["agt_r"]}`)
	confirm_holder(fx, "inst_w1")
	// Use the real Hub liveness cache and demand-probe path for submit.
	fx.svc.fixture_process_fact = nil
	wake_log_reset(log)
	sub, submitted, submit_err := lease_submit(&fx.svc, inst_auth("inst_w1"), Submit_Input{summary = "ready for review"})
	if !testing.expect(t, submitted, submit_err.message) do return
	testing.expect_value(t, sub.outcome, "in_review")
	testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
	worker_claim, held := lease_of(fx, "inst_w1")
	testing.expect(t, held && worker_claim.phase == domain.LEASE_PHASE_WAITING, "submit retains waiting work ownership")
	testing.expect(t, probe.calls == 0, "a submit transaction never waits for a Bridge probe")
	recheck, checked, check_err := task_recheck(&fx.svc, get_task(fx, "task_1"), actor_from_auth(user_auth()))
	testing.expect(t, checked && !recheck.changed, check_err.message)
	testing.expect(t, recheck_reasons_contain(recheck, "waiting on review from agt_r: instance inst_r1 on bridge br_1 has unverified process state"), fmt.tprintf("%v", recheck.reasons))
	testing.expect(t, !recheck_reasons_contain(recheck, worker_claim.lease_id), "a retained waiting work claim is not a live lease blocker")

	drain_match_probe(&fx.svc)
	testing.expect(t, probe.calls == 1, "matching asks the owning Bridge for process evidence")
	review, granted := lease_of(fx, "inst_r1")
	if !absence_verified {
		testing.expect(t, !granted && !wake_log_has_run(log, "inst_r1"), "an inconclusive probe admits neither a lease nor a launch")
		testing.expect_value(t, get_task(fx, "task_1").state, domain.Task_State.In_Review)
		queued, checked_again, _ := task_recheck(&fx.svc, get_task(fx, "task_1"), actor_from_auth(user_auth()))
		testing.expect(t, checked_again && !queued.changed && recheck_reasons_contain(queued, "invalid_probe"), "re-check explains the inconclusive observation")
		return
	}
	testing.expect(t, granted && review.kind == domain.LEASE_KIND_REVIEW && review.task_id == "task_1", "the idle-stopped reviewer is granted a review lease")
	testing.expect(t, wake_log_has_run(log, "inst_r1"), "the reviewer launch is sent after commit")
	restarted, found, _ := iface.agent_get_instance(&fx.agents, "inst_r1")
	defer domain.agent_instance_destroy(&restarted)
	testing.expect(t, found && restarted.run_count == reviewer.run_count + 1, "launch opens one fresh generation on the same instance")
	ordinary := agent.agent_liveness(&log.service, reviewer, cache_only = true)
	testing.expect_value(t, ordinary.state, agent.Agent_Liveness_State.Unknown)
	if !granted do return
	confirm_holder(fx, "inst_r1")
	confirmed, held_by_reviewer := lease_of(fx, "inst_r1")
	testing.expect(t, held_by_reviewer && confirmed.lease_id == review.lease_id && confirmed.confirmed_at != "", "reviewer startup acknowledges the assigned review")
}
