package card

import "core:strings"
import "core:testing"
import domain "odin_test:hub/domain"
import platform "odin_test:hub/platform"
import iface "odin_test:hub/repository/iface"
import agent_service "odin_test:hub/service/agent"

// Owner-chain tasks needing the user (design B, user 18:40Z): the owner
// Bridge's in-memory owner_attention snapshot is merged into the attention
// deck as task items (provider owner_task) at read time, scoped to chains the
// owner registry routes to that Bridge, and gone once a snapshot drops them or
// the Bridge disconnects. Ids and flags only; nothing is stored.

@(private = "file")
ot_get_bridge :: proc(ctx: rawptr, bridge_id: string) -> (domain.Bridge, bool, domain.Domain_Error) {
	owner := ""
	switch bridge_id {
	case "brg_owner", "brg_other_mine": owner = string(PH_OWNER)
	case "brg_foreign": owner = "usr_other"
	case: return {}, false, domain.domain_error(.Not_Found, "bridge not found")
	}
	return domain.Bridge{bridge_id = strings.clone(bridge_id), owner_user_id = domain.User_ID(strings.clone(owner))}, true, {}
}

@(private = "file")
ot_routes :: proc(ctx: rawptr, account, chain: string) -> ([]domain.Owner_Registry_Record, domain.Domain_Error) {
	out := make([dynamic]domain.Owner_Registry_Record, context.temp_allocator)
	if account == string(PH_OWNER) {
		append(&out, domain.Owner_Registry_Record{account_id = account, chain_id = "chain_owned", owner_bridge_id = "brg_owner"})
		append(&out, domain.Owner_Registry_Record{account_id = account, chain_id = "chain_elsewhere", owner_bridge_id = "brg_other_mine"})
	} else {
		append(&out, domain.Owner_Registry_Record{account_id = account, chain_id = "chain_foreign", owner_bridge_id = "brg_foreign"})
	}
	return out[:], {}
}

@(private = "file")
ot_pushes: [dynamic]string

@(private = "file")
ot_push_hook :: proc(ctx: rawptr, owner: string, fresh: int, chain: string) {
	append(&ot_pushes, strings.concatenate({owner, "|", chain}, context.temp_allocator))
}

@(test)
test_attention_merges_owner_chain_tasks_needing_the_user :: proc(t: ^testing.T) {
	h: Projector_Harness
	ph_open(t, &h, "att_api_owner_tasks")
	defer ph_close(&h)

	bridges := iface.Bridge_Repository{get_bridge = ot_get_bridge}
	chains := iface.Taskchain_Repository{owner_registry_routes = ot_routes}
	agents := agent_service.new_agent_service(nil, &bridges, &h.clock, &h.ids)
	agents.taskchains = &chains
	ot_pushes = make([dynamic]string, context.temp_allocator)
	agents.owner_attention_hook = ot_push_hook
	h.svc.agents = &agents

	snapshot := `{"type":"owner_attention","protocol_version":1,"items":[` +
		`{"chain_id":"chain_owned","task_id":"T-1","attention":"blocked","badge":"question","state":"ready","attempt":"1"},` +
		`{"chain_id":"chain_owned","task_id":"T-2","attention":"review","badge":"review","state":"in_review","attempt":"2"},` +
		// Not this Bridge's chain, a bad badge, and plaintext extras: dropped / ignored.
		`{"chain_id":"chain_elsewhere","task_id":"T-9","attention":"blocked","badge":"question","state":"ready","attempt":"1"},` +
		`{"chain_id":"chain_owned","task_id":"T-3","attention":"blocked","badge":"anything","state":"ready","attempt":"1"},` +
		`{"chain_id":"chain_owned","task_id":"T-4","attention":"blocked","badge":"agent_not_running","state":"ready","attempt":"0","title":"secret"}]}`
	testing.expect(t, agent_service.apply_bridge_owner_attention(&agents, "brg_owner", snapshot))
	testing.expect(t, agent_service.apply_bridge_owner_attention(&agents, "brg_foreign", `{"items":[{"chain_id":"chain_foreign","task_id":"X","attention":"blocked","badge":"question","state":"ready","attempt":"1"}]}`))
	testing.expect(t, !agent_service.apply_bridge_owner_attention(&agents, "brg_unknown", `{"items":[]}`))
	testing.expect_value(t, len(ot_pushes), 2) // one per Bridge snapshot with new items
	if len(ot_pushes) == 2 do testing.expect_value(t, ot_pushes[0], string(PH_OWNER) + "|chain_owned")

	r, err := list_attention(&h.svc, ph_auth(), "", "", true)
	testing.expect_value(t, err.code, domain.Error_Code.None)
	testing.expect_value(t, r.counts.task, 3)
	testing.expect_value(t, len(r.items), 3)
	ids := make(map[string]Attention_Item, 4, context.temp_allocator)
	for it in r.items do ids[string(it.card.card_id)] = it
	t1, has1 := ids["otask:brg_owner:chain_owned:T-1"]
	testing.expect(t, has1)
	testing.expect_value(t, t1.card.kind, domain.CARD_KIND_TASK)
	testing.expect_value(t, t1.card.provider, agent_service.OWNER_ATTENTION_KIND)
	testing.expect_value(t, t1.reason, ATTENTION_REASON_QUESTION)
	testing.expect_value(t, t1.card.title, "")
	testing.expect_value(t, t1.card.operations_json, "[]")
	testing.expect_value(t, t1.card.details_json, `{"attention":"blocked","badge":"question","state":"ready","attempt_no":1,"owner_chain":true}`)
	testing.expect_value(t, t1.card.action_refs_json, `{"chain_id":"chain_owned","task_id":"T-1","bridge_id":"brg_owner"}`)
	testing.expect_value(t, t1.card.attention_since, platform.clock_now(&h.clock))
	testing.expect_value(t, ids["otask:brg_owner:chain_owned:T-2"].reason, ATTENTION_REASON_AWAITING_REVIEW)
	testing.expect_value(t, ids["otask:brg_owner:chain_owned:T-4"].reason, "agent_not_running")
	testing.expect(t, !strings.contains(ids["otask:brg_owner:chain_owned:T-4"].card.details_json, "secret"))
	// Another owner's items never show; kind filters keep them under task.
	ro, _ := list_attention(&h.svc, ph_auth("usr_other"), "all", "", true)
	testing.expect_value(t, len(ro.items), 1)
	rm, _ := list_attention(&h.svc, ph_auth(), "all", domain.CARD_KIND_MESSAGE, true)
	testing.expect_value(t, len(rm.items), 0)

	// The same snapshot again: nothing new, no push.
	testing.expect(t, agent_service.apply_bridge_owner_attention(&agents, "brg_owner", snapshot))
	testing.expect_value(t, len(ot_pushes), 2)

	// Resolved (dropped from the next snapshot): gone, no push.
	testing.expect(t, agent_service.apply_bridge_owner_attention(&agents, "brg_owner", `{"items":[{"chain_id":"chain_owned","task_id":"T-2","attention":"review","badge":"review","state":"in_review","attempt":"2"}]}`))
	testing.expect_value(t, len(ot_pushes), 2)
	r2, _ := list_attention(&h.svc, ph_auth(), "all", "", true)
	testing.expect_value(t, r2.counts.task, 1)
	testing.expect_value(t, len(r2.items), 1)

	// Bridge offline: its snapshot is dropped until it reconnects.
	testing.expect(t, agent_service.clear_bridge_owner_attention(&agents, "brg_owner"))
	r3, _ := list_attention(&h.svc, ph_auth(), "all", "", true)
	testing.expect_value(t, len(r3.items), 0)
	agent_service.clear_bridge_owner_attention(&agents, "brg_foreign")

	// Never stored: the attention tables hold no owner-task card.
	live, _ := iface.attention_list_cards(&h.attention, PH_OWNER, domain.CARD_KIND_TASK, "", platform.clock_now(&h.clock), 50)
	testing.expect_value(t, len(live), 0)
}
