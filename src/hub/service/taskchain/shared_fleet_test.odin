package taskchain

import "core:testing"
import "core:strings"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import sqlite "odin_test:hub/repository/sqlite"
import agent "odin_test:hub/service/agent"

@(test)
test_shared_fleet_effective_display_and_staffing_only_write :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f: Brief_Contract_Fixture
	if !brief_contract_open(t, &f, "shared_fleet") do return
	defer brief_contract_close(&f)
	bi: sqlite.Bridge_Repo_SQLite
	br := sqlite.new_bridge_repository(&bi, &f.conn)
	_, _, _ = iface.bridge_save_bridge(&br, {bridge_id="fleet_bridge", owner_user_id="owner", created_at="now", updated_at="now"})
	_, _, _ = iface.taskchain_save_directory(&f.repo, {directory_id="fleet_dir", chain_id=f.chain.chain_id, owner_user_id="owner", bridge_id="fleet_bridge", path="/fixture", created_at="now", updated_at="now"})
	row, err := upsert_fleet(&f.svc, f.owner, {chain_id=f.chain.chain_id, agent_id="agt_worker", capacity=1, provider="legacy", model="old-model", has_roles=true, roles={"worker"}})
	if !testing.expect_value(t, err.code, domain.Error_Code.None) do return
	as := agent.new_agent_service(&f.agents, &br, &f.clock, &f.ids)
	as.taskchains = &f.repo
	f.svc.agent_service = &as
	snapshot, changed, e := iface.fleet_settings_save(&br, "owner", "fleet_bridge", {default_runtime={"shared","shared-profile","default-model"}, overrides={{"agt_worker", {"override","override-profile","override-model"}}}})
	if !testing.expect(t, changed && e.code == .None, e.message) do return
	defer domain.fleet_settings_destroy(snapshot)
	effective := effective_placement(&f.svc, f.chain, row)
	testing.expect(t, effective.bridge_id == "fleet_bridge" && effective.bridge_source == "chain_directory" && effective.model_source == "agent_override")
	testing.expect_value(t, effective.provider_profile, "override-profile"); testing.expect_value(t, effective.model, "override-model")
	staffed, se := upsert_fleet(&f.svc, f.owner, {chain_id=f.chain.chain_id, agent_id="agt_worker", capacity=3, has_roles=true, roles={"worker","reviewer"}})
	testing.expect(t, se.code == .None && staffed.capacity == 3 && staffed.provider == "legacy" && staffed.model == "old-model", "managed staffing-only updates preserve audit runtime and review roles")
	_, conflict := upsert_fleet(&f.svc, f.owner, {chain_id=f.chain.chain_id, agent_id="agt_worker", capacity=3, provider="legacy", model="different-model", has_runtime=true})
	testing.expect(t, conflict.code == .Conflict && strings.contains(conflict.details_json, "fleet_runtime_managed"))
	_, cleared := upsert_fleet(&f.svc, f.owner, {chain_id=f.chain.chain_id, agent_id="agt_worker", capacity=3, has_runtime=true})
	testing.expect_value(t, cleared.code, domain.Error_Code.Conflict)
	new_row, ne := upsert_fleet(&f.svc, f.owner, {chain_id=f.chain.chain_id, agent_id="agt_rev", capacity=1, has_roles=true, roles={"reviewer"}})
	testing.expect(t, ne.code == .None && new_row.provider == "" && new_row.model == "", "fresh roles need no legacy runtime values")
	defaulted := effective_placement(&f.svc, f.chain, new_row)
	testing.expect(t, defaulted.model_source == "bridge_default" && defaulted.model == "default-model" && defaulted.provider_profile == "shared-profile")
	for scope in ([]string{"excluded", "manual"}) {
		id := strings.concatenate({"coordinator_", scope}, context.temp_allocator)
		inst, _, _ := iface.agent_save_instance(&f.agents, {agent_instance_id=id, owner_user_id="owner", agent_id="agt_worker", bridge_id="fleet_bridge", runtime_status="running", created_at="now", updated_at="now"})
		testing.expect_value(t, iface.fleet_scope_set(&br, inst, scope).code, domain.Error_Code.None)
		_, created, ce := create_chain(&f.svc, f.owner, {title="explicit orchestration", coordinator_agent_id=id})
		testing.expect(t, created && ce.code == .None, "excluded origins keep their coordinator orchestration contract")
		included, ie := iface.fleet_scope_get(&br, inst)
		testing.expect(t, ie.code == .None && included == (scope == "manual"))
	}
}
