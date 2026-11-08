package taskchain

import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import platform "odin_test:hub/platform"

// F1/B1: only the user may lower a task's approval bar. An agent token (the
// chain coordinator included) may set requires_user_approval but never clear
// it, through the flag or the brief key, nor move a gate's approver off "user".
@(test)
test_agent_cannot_clear_requires_user_approval_or_gate_user_approver :: proc(t: ^testing.T) {
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "ratchet") do return
	defer brief_contract_close(&f)
	now := platform.clock_now(&f.clock)
	_, _, _ = iface.agent_save_instance(&f.agents, domain.Agent_Instance{agent_instance_id = "coord", owner_user_id = "owner", agent_id = "agt_worker", chain_id = string(f.chain.chain_id), created_at = now, updated_at = now})
	_, _, _ = iface.taskchain_save_member(&f.repo, domain.Task_Chain_Member{chain_id = f.chain.chain_id, owner_user_id = "owner", agent_instance_id = "coord", agent_id = "agt_worker", role = "coordinator", created_at = now})
	coord := contracts.Auth_Context{kind = .Instance_Token, user_id = "owner", agent_instance_id = "coord"}
	is_ratchet :: proc(err: domain.Domain_Error) -> bool {
		return err.code == .Forbidden && strings.contains(err.details_json, "user_approval_ratchet")
	}

	flagged, ok, err := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "flagged", brief_json = `{"goal":"g","acceptance":["a"],"requires_user_approval":true}`, requires_user_approval = true, has_requires_user_approval = true})
	if !testing.expectf(t, ok, "create: %s", err.message) do return
	_, uok, uerr := update_task(&f.svc, coord, flagged.task_id, Update_Task_Input{requires_user_approval = false, has_requires_user_approval = true})
	testing.expect(t, !uok && is_ratchet(uerr), "coordinator cannot clear the flag")
	_, bok, berr := update_task(&f.svc, coord, flagged.task_id, Update_Task_Input{brief_json = `{"requires_user_approval":false}`})
	testing.expect(t, !bok && is_ratchet(berr), "coordinator cannot clear the brief key")
	_, nok, nerr := update_task(&f.svc, coord, flagged.task_id, Update_Task_Input{brief_json = `{"requires_user_approval":null}`})
	testing.expect(t, !nok && is_ratchet(nerr), "coordinator cannot null the brief key")
	stored, _, _ := iface.taskchain_get_task(&f.repo, flagged.task_id)
	testing.expect(t, stored.requires_user_approval, "flag unchanged after refusals")
	// unrelated edits by the coordinator still work
	_, gok, gerr := update_task(&f.svc, coord, flagged.task_id, Update_Task_Input{brief_json = `{"goal":"sharper"}`})
	testing.expectf(t, gok, "coordinator goal edit: %s", gerr.message)
	// the user may clear it
	cleared, cok, cerr := update_task(&f.svc, f.owner, flagged.task_id, Update_Task_Input{requires_user_approval = false, has_requires_user_approval = true, brief_json = `{"requires_user_approval":false}`})
	testing.expect(t, cok && !cleared.requires_user_approval, cerr.message)

	// the coordinator may raise the bar
	plain, pok, _ := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "plain", brief_json = `{"goal":"g","acceptance":["a"]}`})
	if !testing.expect(t, pok, "create plain") do return
	raised, rok, rerr := update_task(&f.svc, coord, plain.task_id, Update_Task_Input{requires_user_approval = true, has_requires_user_approval = true})
	testing.expect(t, rok && raised.requires_user_approval, rerr.message)

	// a user approver stays the user's
	gate, gtok, gterr := create_task(&f.svc, f.owner, Create_Task_Input{chain_id = f.chain.chain_id, title = "gate", brief_json = `{"goal":"g","acceptance":["a"],"approver":"user"}`})
	if !testing.expectf(t, gtok, "create gate-approver task: %s", gterr.message) do return
	_, aok, aerr := update_task(&f.svc, coord, gate.task_id, Update_Task_Input{brief_json = `{"approver":"user_or_coordinator"}`})
	testing.expect(t, !aok && is_ratchet(aerr), "coordinator cannot move the approver off the user")
	_, a2ok, a2err := update_task(&f.svc, f.owner, gate.task_id, Update_Task_Input{brief_json = `{"approver":"user_or_coordinator"}`})
	testing.expectf(t, a2ok, "the user may: %s", a2err.message)
}
