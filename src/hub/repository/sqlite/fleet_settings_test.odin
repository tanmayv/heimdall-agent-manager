#+private file
package sqlite

import "core:testing"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"

@(test)
test_shared_fleet_snapshot_revision_owner_and_atomicity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	bi: Bridge_Repo_SQLite; br := new_bridge_repository(&bi, &conn)
	ai: Agent_Repo_SQLite; ar := new_agent_repository(&ai, &conn)
	for id in ([]string{"b1", "b2"}) {
		_, saved, e := iface.bridge_save_bridge(&br, {bridge_id=id, owner_user_id="owner", created_at="now", updated_at="now"})
		testing.expect(t, saved && e.code == .None)
	}
	for id in ([]string{"a1", "a2"}) {
		_, saved, e := iface.agent_save(&ar, {agent_id=id, owner_user_id="owner", name=id, slug=id, created_at="now", updated_at="now"})
		testing.expect(t, saved && e.code == .None)
	}
	_, _, _ = iface.agent_save(&ar, {agent_id="foreign", owner_user_id="other", name="foreign", slug="foreign", created_at="now", updated_at="now"})
	initial, e := iface.fleet_settings_get(&br, "owner", "b1")
	testing.expect(t, e.code == .None && initial.revision == 0, "migration does not establish shared authority")
	_, denied := iface.fleet_settings_get(&br, "other", "b1")
	testing.expect_value(t, denied.code, domain.Error_Code.Not_Found)
	draft := domain.Fleet_Settings_Draft{default_runtime={"codex","work-profile","model-1"}, overrides={{"a1", {"claude","claude","model-2"}}}}
	saved, changed, err := iface.fleet_settings_save(&br, "owner", "b1", draft)
	if !testing.expect(t, changed && err.code == .None, err.message) do return
	testing.expect_value(t, saved.revision, i64(1)); testing.expect_value(t, saved.default_runtime.provider_profile, "work-profile")
	testing.expect_value(t, len(saved.overrides), 1)
	_, _, stale := iface.fleet_settings_save(&br, "owner", "b1", draft)
	testing.expect_value(t, stale.code, domain.Error_Code.Conflict)
	draft.expected_revision = 1
	unchanged, no_change, noerr := iface.fleet_settings_save(&br, "owner", "b1", draft)
	testing.expect(t, noerr.code == .None && !no_change && unchanged.revision == 1, "no-op does not advance revision")
	bad := draft; bad.overrides = {{"foreign", {"codex","codex","x"}}}
	_, _, invalid := iface.fleet_settings_save(&br, "owner", "b1", bad)
	testing.expect_value(t, invalid.code, domain.Error_Code.Not_Found)
	bad.overrides = {{"a1", {"codex","codex","x"}}, {"a1", {"codex","codex","y"}}}
	_, _, duplicate := iface.fleet_settings_save(&br, "owner", "b1", bad)
	testing.expect_value(t, duplicate.code, domain.Error_Code.Unprocessable_Entity)
	still, _ := iface.fleet_settings_get(&br, "owner", "b1")
	testing.expect(t, still.revision == 1 && still.default_runtime.provider_profile == "work-profile" && len(still.overrides) == 1, "failed snapshot writes leave prior snapshot intact")
	other, _ := iface.fleet_settings_get(&br, "owner", "b2")
	testing.expect_value(t, other.revision, i64(0))
	draft.overrides = nil
	cleared, did_clear, clearerr := iface.fleet_settings_save(&br, "owner", "b1", draft)
	testing.expect(t, clearerr.code == .None && did_clear && cleared.revision == 2 && len(cleared.overrides) == 0, "removing last override restores inheritance")
	// Embedded migration replay is safe and never imports per-chain runtime data.
	testing.expect(t, exec(&conn, MIGRATION_253_SHARED_FLEET_SETTINGS))
}

@(test)
test_shared_fleet_scope_manual_legacy_promotion_and_exclusions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	bi: Bridge_Repo_SQLite; br := new_bridge_repository(&bi, &conn)
	ai: Agent_Repo_SQLite; ar := new_agent_repository(&ai, &conn)
	ti: Taskchain_Repo_SQLite; tr := new_taskchain_repository(&ti, &conn)
	_, _, _ = iface.bridge_save_bridge(&br, {bridge_id="b", owner_user_id="owner", created_at="now", updated_at="now"})
	_, _, _ = iface.agent_save(&ar, {agent_id="a", owner_user_id="owner", name="a", slug="a", created_at="now", updated_at="now"})
	chain, _, _ := iface.taskchain_save_chain(&tr, {chain_id="chain", owner_user_id="owner", title="private", kind=domain.CHAIN_KIND_MIXED_WORK, publish_state=.Published, created_at="now", updated_at="now"})
	for id in ([]string{"unknown", "manual", "explicit", "bot", "test", "action", "bound_bot"}) {
		inst, saved, e := iface.agent_save_instance(&ar, {agent_instance_id=id, agent_id="a", bridge_id="b", owner_user_id="owner", chain_id="chain", kind="provider_test" if id=="test" else "agent", runtime_status="stopped", created_at="now", updated_at="now"})
		testing.expect(t, saved && e.code == .None)
		_, _, _ = iface.taskchain_save_member(&tr, {chain_id=chain.chain_id, agent_instance_id=id, agent_id="a", owner_user_id="owner", role="coordinator", created_at="now"})
		if id == "manual" do testing.expect_value(t, iface.fleet_scope_set(&br, inst, "manual").code, domain.Error_Code.None)
		if id == "bot" do testing.expect_value(t, iface.fleet_scope_set(&br, inst, "excluded").code, domain.Error_Code.None)
		if id == "explicit" do testing.expect_value(t, iface.fleet_scope_set(&br, inst, "chain").code, domain.Error_Code.None)
		if id == "bound_bot" do testing.expect(t, exec(&conn, "INSERT INTO bots(bot_id,owner_user_id,agent_id,agent_instance_id,created_at,updated_at) VALUES('bot','owner','a','bound_bot','now','now');"))
		if id == "action" do testing.expect(t, exec(&conn, "INSERT INTO actions(action_id,owner_user_id,prompt_text,target_kind,created_at,updated_at) VALUES('action','owner','prompt','agent','now','now'); INSERT INTO action_runs(run_id,action_id,trigger_id,owner_user_id,occurrence_key,event_type,state,target_instance_id,created_at) VALUES('run','action','trigger','owner','occurrence','test','queued','action','now');"))
		included, se := iface.fleet_scope_get(&br, inst)
		testing.expect(t, se.code == .None && included == (id == "explicit"), "empty mixed_work/coordinator alone is not task evidence")
	}
	_, _ = iface.taskchain_upsert_fleet(&tr, {task_chain_id=chain.chain_id, agent_id="a", capacity=1, roles_json=`["worker"]`, created_at="now", updated_at="now"})
	for id in ([]string{"unknown", "manual", "explicit", "bot", "test", "action", "bound_bot"}) {
		inst, _, _ := iface.agent_get_instance(&ar, id)
		included, se := iface.fleet_scope_get(&br, inst)
		testing.expect(t, se.code == .None && included == (id == "unknown" || id == "explicit"), "same durable agent does not make manual or excluded instances task managed")
		if id == "manual" {
			testing.expect_value(t, iface.fleet_scope_set(&br, inst, "chain").code, domain.Error_Code.None)
			promoted, _ := iface.fleet_scope_get(&br, inst); testing.expect(t, promoted, "trusted claim promotes manual instance")
		}
		if id == "bot" || id == "test" || id == "action" || id == "bound_bot" {
			scope, _ := iface.fleet_scope_classify(&br, inst)
			testing.expect_value(t, scope, domain.Fleet_Scope.Excluded)
			testing.expect_value(t, iface.fleet_scope_set(&br, inst, "chain").code, domain.Error_Code.Conflict)
		}
		inst.owner_user_id = "other"
		_, denied := iface.fleet_scope_get(&br, inst); testing.expect_value(t, denied.code, domain.Error_Code.Not_Found)
	}
}
