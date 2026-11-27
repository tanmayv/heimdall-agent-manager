package sqlite

import "core:mem"
import "core:strings"
import "core:testing"
import contracts "odin_test:contracts"
import domain "odin_test:hub/domain"
import iface "odin_test:hub/repository/iface"
import provider "odin_test:hub/service/provider"

@(test)
test_codex_catalog_upgrade_preserves_pty_profiles_and_snapshot :: proc(t: ^testing.T) {
 conn, opened, _ := open(":memory:")
 if !testing.expect(t, opened) do return
 defer close(&conn)
 migrated, err := run_migrations(&conn, stop_before="234_codex_acp_transport.sql")
 if !testing.expect(t, migrated, err.message) do return
 impl: Provider_Repo_SQLite
 repo := new_provider_repository(&impl, &conn)
 before, found, before_err := iface.provider_catalog_get(&repo,"codex")
 testing.expect(t,found && before_err.code==.None && before.transports_json==`["pty"]`)
 defer domain.provider_catalog_entry_destroy(before)
 testing.expect(t,exec(&conn,"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('codex_upgrade','owner','','');"))
 testing.expect(t,exec(&conn,"INSERT INTO bridge_provider_profiles(bridge_id,profile_id,provider,state,enabled) VALUES('codex_upgrade','work','codex','ok',1);"))
 testing.expect(t,exec(&conn,"INSERT INTO bridge_provider_settings(bridge_id,profile_id,provider,enabled,updated_at,transport) VALUES('codex_upgrade','codex','codex',1,'','pty'),('codex_upgrade','work','codex',0,'',NULL);"))
 testing.expect(t,exec(&conn,"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,provider,runtime_status,runtime_transport,created_at,updated_at) VALUES('codex_existing','owner','agent','codex_upgrade','codex','running','pty','','');"))
 // Stop right after 234: later release migrations bump extension.min_version
 // (235 moved codex to 0.5.72), so only this window isolates what 234 changed.
 migrated,err=run_migrations(&conn,stop_before="235_extension_version_sync_0_5_72.sql")
 if !testing.expect(t,migrated,err.message) do return
 entry, exists, entry_err := iface.provider_catalog_get(&repo,"codex")
 testing.expect(t,exists && entry_err.code==.None)
 defer domain.provider_catalog_entry_destroy(entry)
 testing.expect(t,entry.transports_json==`["pty","acp"]` && entry.default_transport=="pty")
 testing.expect(t,contracts.acp_provider_recipe_valid("codex",entry.acp_recipe_json))
 // Compare every catalog field/model through the canonical serializer after
 // restoring just the three intentionally changed transport fields.
 same := entry
 same.transports_json=before.transports_json;same.default_transport=before.default_transport;same.acp_recipe_json=before.acp_recipe_json
 old_entries:=make([dynamic]domain.Provider_Catalog_Entry,context.temp_allocator);append(&old_entries,before)
 new_entries:=make([dynamic]domain.Provider_Catalog_Entry,context.temp_allocator);append(&new_entries,same)
 old_body:=provider.catalog_body_json(old_entries);defer delete(old_body)
 new_body:=provider.catalog_body_json(new_entries);defer delete(new_body)
 testing.expect_value(t,new_body,old_body)
 settings,settings_err:=iface.bridge_provider_setting_list(&repo,"codex_upgrade")
 defer domain.bridge_provider_settings_destroy(settings)
 testing.expect(t,settings_err.code==.None && len(settings)==2)
 for setting in settings {
  testing.expect_value(t,setting.transport,"pty" if setting.profile_id=="codex" else "")
  testing.expect_value(t,setting.enabled,setting.profile_id=="codex")
 }
 stored,stored_err:=iface.provider_catalog_etag(&repo);defer delete(stored)
 service:=provider.Provider_Service{repo=&repo}
 derived,derived_err:=provider.catalog_etag(&service);defer delete(derived)
 testing.expect(t,stored_err.code==.None && derived_err.code==.None && stored==derived)
 // Both on-disk and embedded migrations carry the same reviewed bytes.
 embedded:=migration_sql("234_codex_acp_transport.sql","");defer delete(embedded)
 disk:=migration_sql("234_codex_acp_transport.sql","src/hub/repository/sqlite/migrations");defer delete(disk)
 testing.expect_value(t,embedded,disk)
 // Later release migrations change extension versions and therefore the hash;
 // the stored/runtime-derived equality must still hold on the current head.
 migrated,err=run_migrations(&conn)
 if !testing.expect(t,migrated,err.message) do return
 head_stored,head_stored_err:=iface.provider_catalog_etag(&repo);defer delete(head_stored)
 head_derived,head_derived_err:=provider.catalog_etag(&service);defer delete(head_derived)
 testing.expect(t,head_stored_err.code==.None && head_derived_err.code==.None && head_stored==head_derived)
 head,head_found,_:=iface.provider_catalog_get(&repo,"codex");defer domain.provider_catalog_entry_destroy(head)
 testing.expect(t,head_found && head.transports_json==`["pty","acp"]` && head.default_transport=="pty")
 // The agent repository reads columns added after 234, so check the running
 // instance kept its transport on the fully migrated schema.
 agent_impl:Agent_Repo_SQLite
 agents:=new_agent_repository(&agent_impl,&conn)
 inst,inst_found,inst_err:=iface.agent_get_instance(&agents,"codex_existing")
 defer domain.agent_instance_destroy(&inst)
 testing.expect(t,inst_found && inst_err.code==.None && inst.runtime_transport=="pty")
 // Replaying the migration ledger is idempotent.
 migrated,err=run_migrations(&conn)
 testing.expect(t,migrated,err.message)
}

@(test)
c2_copilot_catalog_upgrade_preserves_profiles_defaults_and_hash :: proc(t: ^testing.T) {
 conn, opened, _ := open(":memory:")
 if !testing.expect(t, opened) do return
 defer close(&conn)
 migrated, err := run_migrations(&conn, stop_before="224_copilot_acp_transport.sql")
 if !testing.expect(t, migrated, err.message) do return
 impl: Provider_Repo_SQLite
 repo := new_provider_repository(&impl, &conn)
 before, found, before_err := iface.provider_catalog_get(&repo,"copilot")
 testing.expect(t,found && before_err.code==.None && before.transports_json==`["pty"]`)
 defer domain.provider_catalog_entry_destroy(before)
 testing.expect(t,exec(&conn,"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('c2','owner','','');"))
 testing.expect(t,exec(&conn,"INSERT INTO bridge_provider_profiles(bridge_id,profile_id,provider,state,enabled) VALUES('c2','work','copilot','ok',1);"))
 testing.expect(t,exec(&conn,"INSERT INTO bridge_provider_settings(bridge_id,profile_id,provider,enabled,updated_at,transport) VALUES('c2','copilot','copilot',1,'',NULL),('c2','work','copilot',0,'',NULL);"))
 migrated,err=run_migrations(&conn)
 if !testing.expect(t,migrated,err.message) do return
 entry, exists, entry_err := iface.provider_catalog_get(&repo,"copilot")
 testing.expect(t,exists && entry_err.code==.None)
 defer domain.provider_catalog_entry_destroy(entry)
 testing.expect(t,entry.transports_json==`["pty","acp"]` && entry.default_transport=="pty")
 testing.expect(t,contracts.acp_provider_recipe_valid("copilot",entry.acp_recipe_json))
 testing.expect_value(t,entry.binary,before.binary)
 testing.expect_value(t,entry.bootstrap_file,before.bootstrap_file)
 settings,settings_err:=iface.bridge_provider_setting_list(&repo,"c2")
 defer domain.bridge_provider_settings_destroy(settings)
 testing.expect(t,settings_err.code==.None && len(settings)==2)
 for setting in settings do testing.expect(t,setting.transport=="" && setting.enabled==(setting.profile_id=="copilot"))
 stored,stored_err:=iface.provider_catalog_etag(&repo);defer delete(stored)
 service:=provider.Provider_Service{repo=&repo}
 derived,derived_err:=provider.catalog_etag(&service);defer delete(derived)
 testing.expect(t,stored_err.code==.None && derived_err.code==.None && stored==derived)
 // Later release migrations update extension versions and therefore the hash.
 // The stored/runtime-derived equality above remains valid across releases.
 pi,pi_found,_:=iface.provider_catalog_get(&repo,"pi");defer domain.provider_catalog_entry_destroy(pi)
 testing.expect(t,pi_found && pi.transports_json==`["pty"]`)
 // Replaying the migration ledger is idempotent.
 migrated,err=run_migrations(&conn)
 testing.expect(t,migrated,err.message)
}

@(test)
test_transport_migration_upgrades_pre210_copy_and_preserves_profiles :: proc(t:^testing.T) {
 source,ok,_:=open(":memory:")
 if !testing.expect(t,ok) do return
 defer close(&source)
 migrated,err:=run_migrations(&source,stop_before="210_extension_version_sync_0_5_56.sql")
 if !testing.expect(t,migrated,err.message) do return
 testing.expect(t,exec(&source,"INSERT INTO bridges(bridge_id,owner_user_id,created_at,updated_at) VALUES('transport','owner','','');"))
 testing.expect(t,exec(&source,"INSERT INTO bridge_provider_profiles(bridge_id,profile_id,provider,state,enabled) VALUES('transport','work','claude','ok',1);"))
 testing.expect(t,exec(&source,"INSERT INTO bridge_provider_settings(bridge_id,profile_id,provider,enabled,updated_at) VALUES('transport','claude','claude',1,''),('transport','work','claude',0,'');"))
 testing.expect(t,exec(&source,"INSERT INTO agent_instances(agent_instance_id,owner_user_id,agent_id,bridge_id,provider,runtime_status,created_at,updated_at) VALUES('old','owner','agent','transport','claude','running','','');"))
 // Upgrade a real SQLite backup, not a representative hand-built schema.
 copy,opened,_:=open(":memory:")
 if !testing.expect(t,opened) do return
 defer close(&copy)
 backup:=tmpl_sqlite3_backup_init(copy.db,"main",source.db,"main")
 if !testing.expect(t,backup!=nil) do return
 testing.expect_value(t,tmpl_sqlite3_backup_step(backup,-1),SQLITE_DONE)
 testing.expect_value(t,tmpl_sqlite3_backup_finish(backup),SQLITE_OK)
 migrated,err=run_migrations(&copy)
 if !testing.expect(t,migrated,err.message) do return
 impl:Provider_Repo_SQLite
 repo:=new_provider_repository(&impl,&copy)
 settings,serr:=iface.bridge_provider_setting_list(&repo,"transport")
 testing.expect_value(t,serr.code,domain.Error_Code.None)
 defer domain.bridge_provider_settings_destroy(settings)
 testing.expect_value(t,len(settings),2)
 for setting in settings {
  testing.expect_value(t,setting.transport,"")
  testing.expect_value(t,setting.enabled,setting.profile_id=="claude")
 }
 profiles,perr:=bridge_provider_profiles_list_sqlite(&impl,"transport")
 testing.expect_value(t,perr.code,domain.Error_Code.None)
 defer domain.bridge_provider_profiles_destroy(profiles)
 testing.expect_value(t,len(profiles),1)
 if len(profiles)>0 do testing.expect_value(t,profiles[0].profile_id,"work")
 aimpl:Agent_Repo_SQLite
 arepo:=new_agent_repository(&aimpl,&copy)
 old,found,aerr:=iface.agent_get_instance(&arepo,"old")
 testing.expect(t,found,aerr.message)
 defer domain.agent_instance_destroy(&old)
 testing.expect_value(t,old.runtime_transport,"pty")
 testing.expect(t,sqlite_object_exists(&copy,"acp_assistant_turns"))
 // Restart after a committed migration whose ledger write was interrupted.
 testing.expect(t,exec(&copy,"DELETE FROM schema_migrations WHERE version='211_provider_transport.sql';"))
 migrated,err=run_migrations(&copy)
 testing.expect(t,migrated,err.message)
}

@(test)
test_transport_catalog_constraints_and_pin :: proc(t:^testing.T) {
 conn,ok:=tmpl_clone_migrated(t)
 if !ok do return
 defer close(&conn)
 impl:Provider_Repo_SQLite
 repo:=new_provider_repository(&impl,&conn)
 entry,found,err:=iface.provider_catalog_get(&repo,"claude")
 testing.expect(t,found,err.message)
 defer domain.provider_catalog_entry_destroy(entry)
 testing.expect_value(t,entry.transports_json,`["pty","acp"]`)
 testing.expect_value(t,entry.default_transport,"pty")
 testing.expect(t,contracts.acp_recipe_valid(entry.acp_recipe_json))
 testing.expect(t,strings.contains(entry.acp_recipe_json,`"adapter_version":"0.108.0"`))
 for sql in ([]string{
  "UPDATE provider_catalog SET transports='[]' WHERE provider='claude';",
  "UPDATE provider_catalog SET transports='[\"pty\",\"pty\"]' WHERE provider='claude';",
  "UPDATE provider_catalog SET transports='[\"pty\",1]' WHERE provider='claude';",
  "UPDATE provider_catalog SET transports='[\"other\"]' WHERE provider='claude';",
  "UPDATE provider_catalog SET default_transport='acp' WHERE provider='pi';",
  "UPDATE provider_catalog SET acp_recipe=NULL WHERE provider='claude';",
  "UPDATE provider_catalog SET acp_recipe='[]' WHERE provider='claude';",
  "UPDATE provider_catalog SET transports='bad' WHERE provider='claude';",
  "INSERT INTO bridge_provider_settings(bridge_id,provider,profile_id,enabled,updated_at,transport) VALUES('b','claude','claude',1,'','other');",
  "INSERT INTO bridge_provider_settings(bridge_id,provider,profile_id,enabled,updated_at,transport) VALUES('b','claude','work',1,'','other');",
 }) { testing.expect(t,!exec(&conn,sql),sql) }
 // G6 (269): any profile may hold its own transport.
 testing.expect(t,exec(&conn,"INSERT INTO bridge_provider_settings(bridge_id,provider,profile_id,enabled,updated_at,transport) VALUES('b','claude','work',1,'','pty');"))
}

@(test)
test_transport_only_save_never_decides_enablement_and_preserves_other_profiles :: proc(t:^testing.T) {
 conn,ok:=tmpl_clone_migrated(t)
 if !ok do return
 defer close(&conn)
 impl:Provider_Repo_SQLite
 repo:=new_provider_repository(&impl,&conn)
 _,err:=iface.bridge_provider_status_upsert(&repo,{bridge_id="b",provider="claude",state="present"})
 testing.expect_value(t,err.code,domain.Error_Code.None)
 err=iface.set_provider_transport(&repo,"b","claude","acp","now")
 testing.expect_value(t,err.code,domain.Error_Code.None)
 settings,_:=iface.bridge_provider_setting_list(&repo,"b")
 testing.expect_value(t,len(settings),1)
 // The new row holds only the transport: enablement stays derived (NULL).
 if len(settings)>0 {testing.expect(t,settings[0].enabled_implicit);testing.expect_value(t,settings[0].transport,"acp")}
 domain.bridge_provider_settings_destroy(settings)
 _,err=iface.bridge_provider_setting_upsert(&repo,{bridge_id="b",provider="claude",enabled=false})
 testing.expect_value(t,err.code,domain.Error_Code.None)
 transport,terr:=iface.get_provider_transport(&repo,"b","claude")
 testing.expect_value(t,terr.code,domain.Error_Code.None)
 testing.expect_value(t,transport,"acp")
 delete(transport)
 _,err=iface.bridge_provider_setting_upsert(&repo,{bridge_id="b",provider="claude",profile_id="work",enabled=true})
 testing.expect_value(t,err.code,domain.Error_Code.None)
 err=iface.set_provider_transport(&repo,"b","claude","","later")
 testing.expect_value(t,err.code,domain.Error_Code.None)
 settings,_=iface.bridge_provider_setting_list(&repo,"b")
 defer domain.bridge_provider_settings_destroy(settings)
 testing.expect_value(t,len(settings),2)
 for setting in settings {
  testing.expect_value(t,setting.transport,"")
  // Explicit choices survive a later transport save.
  testing.expect(t,!setting.enabled_implicit)
  testing.expect_value(t,setting.enabled,setting.profile_id=="work")
 }
}

@(test)
test_transport_combined_update_rolls_back_enablement_on_failed_transport :: proc(t:^testing.T) {
 conn,ok:=tmpl_clone_migrated(t)
 if !ok do return
 defer close(&conn)
 impl:Provider_Repo_SQLite
 repo:=new_provider_repository(&impl,&conn)
 factory_impl:SQLite_Unit_Of_Work_Factory
 factory:=new_unit_of_work_factory(&factory_impl,&conn,nil)
 svc:=provider.Provider_Service{repo=&repo,uow_factory=&factory}
 _,_ = iface.bridge_provider_status_upsert(&repo,{bridge_id="b",provider="claude",state="present"})
 _,_ = iface.bridge_provider_setting_upsert(&repo,{bridge_id="b",provider="claude",enabled=true})
 testing.expect(t,exec(&conn,"CREATE TRIGGER fail_transport BEFORE UPDATE OF transport ON bridge_provider_settings BEGIN SELECT RAISE(ABORT,'injected transport failure'); END;"))
 err:=provider.update_bridge_provider_settings(&svc,{bridge_id="b",status=.Offline},"claude","now",{has_enabled=true,enabled=false,has_transport=true,transport="acp"})
 testing.expect(t,err.code!=.None)
 settings,_:=iface.bridge_provider_setting_list(&repo,"b")
 defer domain.bridge_provider_settings_destroy(settings)
 testing.expect_value(t,len(settings),1)
 if len(settings)>0 {testing.expect(t,settings[0].enabled,"enable write must roll back");testing.expect_value(t,settings[0].transport,"")}
}

@(test)
test_transport_status_preserves_latest_adapter_per_profile :: proc(t:^testing.T) {
 conn,ok:=tmpl_clone_migrated(t)
 if !ok do return
 defer close(&conn)
 impl:Provider_Repo_SQLite
 repo:=new_provider_repository(&impl,&conn)
 newer:=`{"state":"ready","checked_at":"2026-11-18T01:00:00Z"}`
 older:=`{"state":"missing","checked_at":"2026-11-17T01:00:00Z"}`
 for value in ([]domain.Bridge_Provider_Status{
  {bridge_id="b",provider="claude",state="present",acp_adapter_json=newer},
  {bridge_id="b",provider="claude",state="present",acp_adapter_json=older},
  {bridge_id="b",provider="claude",state="present"},
  {bridge_id="b",provider="claude",profile_id="work",state="present",acp_adapter_json=older},
 }) {
  _,err:=iface.bridge_provider_status_upsert(&repo,value)
  testing.expect_value(t,err.code,domain.Error_Code.None)
 }
 statuses,_:=iface.bridge_provider_status_list(&repo,"b")
 defer domain.bridge_provider_statuses_destroy(statuses)
 // Each profile row keeps its own latest report (the launch gate of a
 // non-default profile reads it); the receipt time stays the default profile's.
 for status in statuses {
  testing.expect_value(t,status.acp_adapter_json,newer if status.profile_id=="claude" else older)
  testing.expect(t,(status.acp_adapter_received_at!="")==(status.profile_id=="claude"))
 }
}

@(test)
test_transport_snapshot_is_frozen_until_next_launch_generation :: proc(t:^testing.T) {
 conn,ok:=tmpl_clone_migrated(t)
 if !ok do return
 defer close(&conn)
 impl:Agent_Repo_SQLite
 repo:=new_agent_repository(&impl,&conn)
 first,saved,err:=iface.agent_save_instance(&repo,{agent_instance_id="transport",owner_user_id="owner",bridge_id="b",provider="claude",runtime_transport="acp",run_count=1,launch_epoch="one"})
 if !testing.expect(t,saved,err.message) do return
 first.runtime_transport="pty"
 status_saved:domain.Agent_Instance
 status_saved,saved,err=iface.agent_save_instance(&repo,first)
 if status_saved.runtime_transport!=first.runtime_transport do delete(status_saved.runtime_transport)
 testing.expect(t,saved,err.message)
 current,found,_:=iface.agent_get_instance(&repo,"transport")
 if !testing.expect(t,found) do return
 defer domain.agent_instance_destroy(&current)
 testing.expect(t,current.runtime_transport=="acp","same epoch status save must preserve snapshot")
 next:=current;next.runtime_transport="pty";next.run_count=2;next.launch_epoch="two"
 _,saved,err=iface.agent_save_instance(&repo,next)
 testing.expect(t,saved,err.message)
 _,saved,err=iface.agent_save_instance(&repo,first)
 testing.expect(t,!saved,"old generation cannot replace a new snapshot")
 newer,new_found,_:=iface.agent_get_instance(&repo,"transport")
 defer domain.agent_instance_destroy(&newer)
 testing.expect(t,new_found)
 testing.expect_value(t,newer.runtime_transport,"pty")
 testing.expect_value(t,newer.launch_epoch,"two")
}

// Saves borrow their input; a corrected snapshot owns only its replacement.
// Run with the test runner's tracking allocator, including a heap-owned input.
@(test)
test_transport_snapshot_replacement_preserves_borrowed_input_without_leak :: proc(t: ^testing.T) {
	conn, ok := tmpl_clone_migrated(t)
	if !ok do return
	defer close(&conn)
	impl: Agent_Repo_SQLite
	repo := new_agent_repository(&impl, &conn)
	_, saved, err := iface.agent_save_instance(&repo, {agent_instance_id="transport_owned", runtime_transport="acp", run_count=1})
	if !testing.expect(t, saved, err.message) do return
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	original_allocator := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = original_allocator
	for i in 0..<64 {
		input := domain.Agent_Instance{agent_instance_id="transport_owned", runtime_transport=strings.clone("pty"), run_count=1}
		corrected, updated, update_err := iface.agent_save_instance(&repo, input)
		testing.expect(t, updated, update_err.message)
		testing.expect(t, input.runtime_transport == "pty", "borrowed input remains live")
		testing.expect_value(t, corrected.runtime_transport, "acp")
		delete(input.runtime_transport)
		delete(corrected.runtime_transport)
	}
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_opencode_catalog_is_acp_only :: proc(t: ^testing.T) {
 conn, opened, _ := open(":memory:")
 if !testing.expect(t, opened) do return
 defer close(&conn)
 migrated, err := run_migrations(&conn)
 if !testing.expect(t, migrated, err.message) do return
 impl: Provider_Repo_SQLite
 repo := new_provider_repository(&impl, &conn)
 entry, found, entry_err := iface.provider_catalog_get(&repo, "opencode")
 if !testing.expect(t, found && entry_err.code == .None) do return
 defer domain.provider_catalog_entry_destroy(entry)
 testing.expect(t, entry.transports_json == `["acp"]` && entry.default_transport == "acp")
 testing.expect(t, contracts.acp_provider_recipe_valid("opencode", entry.acp_recipe_json))
 stored, stored_err := iface.provider_catalog_etag(&repo); defer delete(stored)
 service := provider.Provider_Service{repo=&repo}
 derived, derived_err := provider.catalog_etag(&service); defer delete(derived)
 testing.expect(t, stored_err.code == .None && derived_err.code == .None && stored == derived)
}
