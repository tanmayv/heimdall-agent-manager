package hub_h5_coordinator_bootstrap_test

// H5: coordinator team-bootstrap authority reconciliation.
// Covers the service-layer invariants that make a bridge-relayed instance token a
// first-class coordinator:
//   1. Same-owner scoping: create_chain stamps owner from the auth context; an
//      instance token for owner A cannot see/act on owner B's chain (Not_Found).
//   2. Membership-coordinator authority: an agent added as a chain member with
//      role "coordinator" (but NOT the designated chain.coordinator_agent_instance_id)
//      is treated as a coordinator by is_chain_coordinator and may update the chain.
//   3. PATCH can set/change the coordinator after creation (Update_Chain_Input
//      .coordinator_agent_instance_id + has_coordinator), with same-chain validation.

import "core:fmt"
import "core:os"
import "core:strings"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import taskchain_service "odin_test:hub/service/taskchain"
import platform "odin_test:hub/platform"

Repo :: struct {
	chains: [8]domain.Task_Chain,
	chain_count: int,
	members: [16]domain.Task_Chain_Member,
	member_count: int,
	instances: [16]domain.Agent_Instance,
	instance_count: int,
	seq: int,
}

now_proc :: proc(ctx: rawptr) -> string { _ = ctx; return "2026-07-22T10:00:00Z" }
id_proc :: proc(ctx: rawptr, prefix: string) -> string {
	r := (^Repo)(ctx); r.seq += 1; return strings.concatenate({prefix, fmt.tprintf("%d", r.seq)})
}

chain_get :: proc(ctx: rawptr, id: domain.Task_Chain_ID) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == id do return r.chains[i], true, domain.Domain_Error{} }
	return domain.Task_Chain{}, false, domain.domain_error(.Not_Found, "chain not found")
}
chain_save :: proc(ctx: rawptr, c: domain.Task_Chain) -> (domain.Task_Chain, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.chain_count { if r.chains[i].chain_id == c.chain_id { r.chains[i] = c; return c, true, domain.Domain_Error{} } }
	r.chains[r.chain_count] = c; r.chain_count += 1; return c, true, domain.Domain_Error{}
}
member_save :: proc(ctx: rawptr, m: domain.Task_Chain_Member) -> (domain.Task_Chain_Member, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.member_count { if r.members[i].chain_id == m.chain_id && r.members[i].agent_instance_id == m.agent_instance_id { r.members[i] = m; return m, true, domain.Domain_Error{} } }
	r.members[r.member_count] = m; r.member_count += 1; return m, true, domain.Domain_Error{}
}
member_list :: proc(ctx: rawptr, id: domain.Task_Chain_ID, owner: domain.User_ID) -> ([]domain.Task_Chain_Member, domain.Domain_Error) {
	r := (^Repo)(ctx)
	out := make([dynamic]domain.Task_Chain_Member)
	for i in 0..<r.member_count { if r.members[i].chain_id == id do append(&out, r.members[i]) }
	return out[:], domain.Domain_Error{}
}
inst_get :: proc(ctx: rawptr, id: string) -> (domain.Agent_Instance, bool, domain.Domain_Error) {
	r := (^Repo)(ctx)
	for i in 0..<r.instance_count { if r.instances[i].agent_instance_id == id do return r.instances[i], true, domain.Domain_Error{} }
	return domain.Agent_Instance{}, false, domain.domain_error(.Not_Found, "instance not found")
}

main :: proc() {
	data: Repo
	clock := platform.Clock{ctx = nil, now = now_proc}
	ids := platform.ID_Generator{ctx = rawptr(&data), generate = id_proc}
	repo := iface.Taskchain_Repository{ctx = rawptr(&data), get_chain = chain_get, save_chain = chain_save, save_member = member_save, list_members_by_chain = member_list}
	agents := iface.Agent_Repository{ctx = rawptr(&data), get_instance = inst_get}
	service := taskchain_service.new_taskchain_service(&repo, &agents, &clock, &ids)

	// Owner alice's coordinator instance.
	alice_coord := "inst_alice_coord"
	data.instances[data.instance_count] = domain.Agent_Instance{agent_instance_id = alice_coord, owner_user_id = "alice", agent_id = "agt_a"}
	data.instance_count += 1

	alice_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = alice_coord}

	// (1) create_chain via instance token: owner stamped from auth, caller becomes
	// the designated coordinator AND a coordinator member.
	chain, ok, err := taskchain_service.create_chain(&service, alice_auth, taskchain_service.Create_Chain_Input{title = "alice chain"})
	check(ok, err.message)
	check(string(chain.owner_user_id) == "alice", "chain owner must be stamped from the instance token's owner")
	check(chain.coordinator_agent_instance_id == alice_coord, "instance-token creator must become the designated coordinator")

	// (1b) same-owner scoping: an instance token for another owner cannot see it.
	bob_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "bob", agent_instance_id = "inst_bob"}
	_, cross_ok, cross_err := taskchain_service.get_chain(&service, bob_auth, chain.chain_id)
	check(!cross_ok && cross_err.code == .Not_Found, "cross-owner instance token must not resolve another owner's chain")

	// (2) membership-coordinator authority: add a SECOND instance as a coordinator
	// MEMBER (not the designated chain coordinator). It must gain coordinator authority.
	alice_coord2 := "inst_alice_coord2"
	data.instances[data.instance_count] = domain.Agent_Instance{agent_instance_id = alice_coord2, owner_user_id = "alice", agent_id = "agt_a", chain_id = string(chain.chain_id)}
	data.instance_count += 1
	_, add_ok, add_err := taskchain_service.add_chain_member(&service, alice_auth, chain.chain_id, alice_coord2, "coordinator")
	check(add_ok, add_err.message)

	coord2_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = alice_coord2}
	// Before the fix this returned Forbidden ("only chain coordinator ...").
	updated, upd_ok, upd_err := taskchain_service.update_chain(&service, coord2_auth, chain.chain_id, taskchain_service.Update_Chain_Input{description = "by coordinator member"})
	check(upd_ok && updated.description == "by coordinator member", upd_err.message)

	// A plain worker member must NOT get coordinator authority.
	worker := "inst_alice_worker"
	data.instances[data.instance_count] = domain.Agent_Instance{agent_instance_id = worker, owner_user_id = "alice", agent_id = "agt_a", chain_id = string(chain.chain_id)}
	data.instance_count += 1
	_, _, _ = taskchain_service.add_chain_member(&service, alice_auth, chain.chain_id, worker, "worker")
	worker_auth := contracts.Auth_Context{kind = .Instance_Token, user_id = "alice", agent_instance_id = worker}
	_, worker_ok, worker_err := taskchain_service.update_chain(&service, worker_auth, chain.chain_id, taskchain_service.Update_Chain_Input{description = "nope"})
	check(!worker_ok && worker_err.code == .Forbidden, "a worker member must not have coordinator authority")

	// (3) PATCH can change the designated coordinator to another same-chain instance.
	changed, chg_ok, chg_err := taskchain_service.update_chain(&service, alice_auth, chain.chain_id, taskchain_service.Update_Chain_Input{coordinator_agent_instance_id = alice_coord2, has_coordinator = true})
	check(chg_ok && changed.coordinator_agent_instance_id == alice_coord2, chg_err.message)

	// Setting a coordinator that does not belong to the chain must be rejected.
	outsider := "inst_alice_outsider"
	data.instances[data.instance_count] = domain.Agent_Instance{agent_instance_id = outsider, owner_user_id = "alice", agent_id = "agt_a"} // no chain, not a member
	data.instance_count += 1
	_, bad_ok, bad_err := taskchain_service.update_chain(&service, alice_auth, chain.chain_id, taskchain_service.Update_Chain_Input{coordinator_agent_instance_id = outsider, has_coordinator = true})
	check(!bad_ok && bad_err.code == .Conflict, "coordinator target must belong to the same chain")

	fmt.println("PASS: hub H5 coordinator bootstrap authority")
}

check :: proc(ok: bool, message: string) { if ok do return; fmt.eprintln(message); os.exit(1) }
